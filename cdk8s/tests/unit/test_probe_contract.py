"""Contract test: no probe exec command may rely on ``$(VAR)`` substitution.

kubelet expands ``$(VAR)`` references in a container's ``command``/``args`` and
in a probe's ``exec.command``, but the only substitution candidates are static
``env:`` entries carrying a literal ``value:``. A name that reaches the
container through ``envFrom`` (or ``env[].valueFrom``) is never expanded, so a
probe written as::

    exec:
      command: [pg_isready, -U, "$(POSTGRES_USER)"]

hands the binary the literal string ``$(POSTGRES_USER)`` as the role name.

That failure is silent in the worst way — it fails *open*. ``pg_isready`` only
speaks the startup protocol, so it reports "accepting connections" and exits 0;
the probe stays green while the server logs an authentication FATAL on every
check. Nothing alerts, and the manifest reads as correct in review, because
``$(VAR)`` really is valid kubelet syntax — just not reachable from ``envFrom``
inside a probe. A human check won't hold against that, so it's a test.

The fix is to let a shell expand the name, since a shell reads the process
environment and that includes ``envFrom`` values::

    exec:
      command: ["sh", "-c", 'exec pg_isready -U "$POSTGRES_USER"']

Scope is the rendered ``dist/`` manifests rather than in-process synth: dist is
the exact YAML that reaches a cluster, so the check covers every deploy unit
infra ships regardless of which construct (or hand-written doc) produced it.
"""

from __future__ import annotations

from pathlib import Path

import yaml

DIST = Path(__file__).resolve().parents[2] / "dist"

PROBES = ("livenessProbe", "readinessProbe", "startupProbe")

FIX_HINT = (
    "use a shell so the name expands from the process environment: "
    '["sh", "-c", \'exec <cmd> -U "$VAR"\']'
)


def _exec_probes(node, path=""):
    """Yield ``(location, probe_type, command)`` for every exec probe under node.

    Walks dicts and lists blindly so the check is independent of resource kind
    and of how deeply the pod template is nested (Deployment, StatefulSet,
    CronJob's jobTemplate, a bare Pod, ...).
    """
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else key
            if key in PROBES and isinstance(value, dict):
                action = value.get("exec")
                if isinstance(action, dict) and isinstance(action.get("command"), list):
                    yield here, key, action["command"]
            yield from _exec_probes(value, here)
    elif isinstance(node, list):
        for index, item in enumerate(node):
            yield from _exec_probes(item, f"{path}[{index}]")


def _findings(doc, source):
    """Probe exec commands in one manifest doc that reference ``$(VAR)``."""
    kind = doc.get("kind", "?")
    name = (doc.get("metadata") or {}).get("name", "?")
    found = []
    for location, probe_type, command in _exec_probes(doc):
        joined = " ".join(str(part) for part in command)
        if "$(" in joined:
            found.append(
                {
                    "source": source,
                    "resource": f"{kind}/{name}",
                    "probe": probe_type,
                    "location": location,
                    "command": joined,
                }
            )
    return found


def _rendered_docs():
    for path in sorted(DIST.rglob("*.k8s.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if isinstance(doc, dict):
                yield path.name, doc


def _report(findings):
    lines = [
        f"{len(findings)} probe exec command(s) reference $(VAR), which kubelet "
        "expands only from static env: entries with a literal value: — never "
        "from envFrom or valueFrom. The name is passed through as a literal "
        "string, and the probe still passes (it fails open), so nothing alerts.",
        "",
    ]
    for f in findings:
        lines += [
            f"  {f['source']}: {f['resource']} {f['probe']}",
            f"    at: {f['location']}",
            f"    command: {f['command']}",
        ]
    lines += ["", f"Fix: {FIX_HINT}"]
    return "\n".join(lines)


def test_no_probe_exec_command_uses_var_substitution():
    findings = []
    probes_checked = 0
    for source, doc in _rendered_docs():
        for _ in _exec_probes(doc):
            probes_checked += 1
        findings += _findings(doc, source)

    # A walker that silently matched nothing (renamed keys, moved dist/, a typo
    # in PROBES) would pass forever — the same fail-open shape as the bug this
    # guards. Assert it actually looked at something.
    assert probes_checked > 0, (
        f"no exec probes found under {DIST} — the walker or the dist/ layout "
        "changed, so this contract is no longer being enforced"
    )
    assert not findings, _report(findings)


def test_detector_flags_the_broken_form():
    """Guard the guard: the walker must catch the pattern, for all three probes.

    Keeps the check above from going vacuous if the key names or the command
    handling ever drift, and pins the two shapes that must stay quiet — a shell
    form that expands at runtime, and a non-exec probe with no command at all.
    """
    doc = {
        "kind": "StatefulSet",
        "metadata": {"name": "example"},
        "spec": {
            "template": {
                "spec": {
                    "containers": [
                        {
                            "name": "broken",
                            "livenessProbe": {
                                "exec": {"command": ["pg_isready", "-U", "$(USER)"]}
                            },
                            "readinessProbe": {
                                "exec": {"command": ["check", "--db=$(DB_NAME)"]}
                            },
                            "startupProbe": {
                                "exec": {"command": ["sh", "-c", "wait $(PORT)"]}
                            },
                        },
                        {
                            "name": "fine",
                            "livenessProbe": {
                                "exec": {
                                    "command": [
                                        "sh",
                                        "-c",
                                        'exec pg_isready -U "$USER"',
                                    ]
                                }
                            },
                            "readinessProbe": {"tcpSocket": {"port": "postgres"}},
                            "startupProbe": {"httpGet": {"path": "/", "port": 8080}},
                        },
                    ]
                }
            }
        },
    }

    findings = _findings(doc, "synthetic")
    assert {f["probe"] for f in findings} == set(PROBES)
    assert all(f["resource"] == "StatefulSet/example" for f in findings)
    assert len(findings) == 3
    # The report names the offending resource, probe, command, and the fix.
    report = _report(findings)
    assert "StatefulSet/example" in report
    assert "--db=$(DB_NAME)" in report
    assert FIX_HINT in report
