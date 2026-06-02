"""Render-parity checker: diff the cdk8s synth (dist/<env>-apps.k8s.yaml) against
the legacy Kustomize render (reference/<env>.kustomize.yaml), normalizing the
*intended* divergences so only real drift surfaces.

Intended divergences (normalized away):
  * ConfigMap/Secret name hashes — Kustomize appends a content hash
    (`tripbot-config-abc123`); cdk8s keeps the stable logical name. We strip a
    trailing `-<base32hash>` from ConfigMap/Secret names AND from envFrom/volume
    references to them, on BOTH sides, before comparing.
  * The `adanalife.dev/config-hash` pod-template annotation cdk8s adds.
  * cdk8s stamps `namespace:` on namespaced objects even when the legacy local
    overlay left it implicit (`default`) — namespace is ignored in the key.

Run:  uv run python tests/parity.py [env ...]
Exits non-zero if any non-intended difference is found. Used by the parity
pytest and runnable standalone during migration.
"""
from __future__ import annotations

import base64
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
HASH_KINDS = {"ConfigMap", "Secret"}
_HASH_SUFFIX = re.compile(r"-[bcdfghjklmnpqrstvwxz2456789]{8,10}$")  # kustomize base32hash

# The pilot's intended rename: the single legacy `obs` becomes the per-platform
# `obs-twitch`. Applied to REFERENCE names so they line up with cdk8s output.
_OBS_RENAME = {
    "obs": "obs-twitch", "obs-host": "obs-twitch-host",
    "obs-config": "obs-twitch-config", "obs-ts": "obs-twitch-ts",
}

# Net-new in cdk8s with no legacy counterpart — allowed EXTRAs (intended):
#   obs-youtube*  — the second streaming platform the migration adds.
_ALLOWED_EXTRA = re.compile(r"^obs-youtube")

# Objects whose field-level DIFF is the migration's documented intent, not drift:
#   obs-twitch* / obs-youtube* — the per-platform OBS factory deliberately renames
#   obs→obs-twitch and uses instance-scoped selectors + richer labels (Phase 1,
#   separately verified). MISSING/EXTRA still report; only DIFF is waived.
_INTENDED_DIFF = re.compile(r"^obs-(twitch|youtube)")


def _strip_hash(name: str) -> str:
    return _HASH_SUFFIX.sub("", name)


def _rename_ref(name: str) -> str:
    return _OBS_RENAME.get(name, name)


def _load(path: Path) -> list[dict]:
    return [d for d in yaml.safe_load_all(path.read_text()) if d]


def _normalize(obj: dict) -> dict:
    """Canonicalize an object so intended deltas don't register as drift."""
    kind = obj.get("kind", "")
    meta = obj.setdefault("metadata", {})
    meta.pop("namespace", None)  # ignore ns (local-overlay implicit-default)
    meta.pop("annotations", None) if meta.get("annotations") == {} else None

    if kind in HASH_KINDS and "name" in meta:
        meta["name"] = _strip_hash(meta["name"])

    # Secrets: canonicalize data(base64) ↔ stringData(plaintext) — k8s treats
    # them identically, so the cdk8s stringData form and kustomize's base64 data
    # are equivalent. Decode everything to a single plaintext `stringData` map.
    if kind == "Secret":
        merged = dict(obj.pop("stringData", {}) or {})
        for k, v in (obj.pop("data", {}) or {}).items():
            try:
                merged[k] = base64.b64decode(v).decode()
            except Exception:
                merged[k] = v
        if merged:
            obj["stringData"] = merged

    # Strip the config-hash annotation from pod templates.
    tmpl = obj.get("spec", {}).get("template", {})
    ann = tmpl.get("metadata", {}).get("annotations")
    if ann:
        ann.pop("adanalife.dev/config-hash", None)
        if not ann:
            tmpl["metadata"].pop("annotations", None)

    # De-hash references to ConfigMaps/Secrets in pod specs (envFrom / volumes),
    # and apply the obs rename to any name reference on the reference side.
    blob = yaml.safe_dump(obj)
    blob = re.sub(r"(name:\s*)([\w-]+-[bcdfghjklmnpqrstvwxz2456789]{8,10})\b",
                  lambda m: m.group(1) + _strip_hash(m.group(2)), blob)
    return yaml.safe_load(blob)


def _key(obj: dict, *, rename: bool = False) -> tuple[str, str]:
    name = _strip_hash(obj.get("metadata", {}).get("name", ""))
    if rename:
        name = _rename_ref(name)
    return obj.get("kind", ""), name


def compare(env: str) -> list[str]:
    """Return a list of human-readable drift messages (empty = parity)."""
    cdk_objs = _load(ROOT / "dist" / f"{env}-apps.k8s.yaml")
    # Local bundles the one-shot Jobs into its umbrella; elsewhere they're a
    # separate deploy unit. Union the jobs file in for local so they line up.
    jobs_file = ROOT / "dist" / f"{env}-jobs.k8s.yaml"
    if env == "local" and jobs_file.exists():
        cdk_objs += _load(jobs_file)

    cdk = {_key(_normalize(o)): _normalize(o) for o in cdk_objs}
    ref = {_key(_normalize(o), rename=True): _normalize(o)
           for o in _load(ROOT / "reference" / f"{env}.kustomize.yaml")}

    problems: list[str] = []
    for k in sorted(ref.keys() - cdk.keys()):
        problems.append(f"MISSING in cdk8s: {k[0]}/{k[1]}")
    for k in sorted(cdk.keys() - ref.keys()):
        if not _ALLOWED_EXTRA.match(k[1]):
            problems.append(f"EXTRA in cdk8s: {k[0]}/{k[1]}")
    for k in sorted(cdk.keys() & ref.keys()):
        if _INTENDED_DIFF.match(k[1]):
            continue  # per-platform OBS rename — intended, verified in Phase 1
        a, b = yaml.safe_dump(cdk[k], sort_keys=True), yaml.safe_dump(ref[k], sort_keys=True)
        if a != b:
            problems.append(f"DIFF {k[0]}/{k[1]}")
    return problems


def main(argv: list[str]) -> int:
    envs = argv or ["development", "stage-1", "prod-1", "local"]
    total = 0
    for env in envs:
        problems = compare(env)
        total += len(problems)
        status = "OK" if not problems else f"{len(problems)} issue(s)"
        print(f"[{env}] {status}")
        for p in problems:
            print(f"    {p}")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
