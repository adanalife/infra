"""Nothing a live pod mounts may come off the NAS.

The stream path runs on node-local storage so a NAS link flap can't take the
stream down (decisions/prod-stream-path-no-nas-dependency). The NFS PVs and the
`vlc-dashcam` / `obs-music` claims that bind them still exist — they're the
staging side the localize Jobs mirror from — so re-pointing a live workload at
one is a one-line change that renders as a plausible diff. This states the rule
the review was relying on someone remembering.

Reads the committed dist/ rather than re-synthing: cdk8s-synth.yml re-synths and
pushes back on every PR, so the two agree, and reading the files catches a
hand-edited manifest as well.

The allowlist is the artifact — the deploy units named there are the ones whose
whole job is to reach the NAS, and by exclusion it's also the first written-down
statement of which units are stream path. It can't see tripbot's or obs's
manifests, which those repos author themselves; obs carries its own PreSync
volume gate, and a mount pointed at a reachable NAS PV passes that gate happily.
"""

from pathlib import Path

import yaml

DIST = Path(__file__).resolve().parents[2] / "dist"

# Deploy units that exist to talk to the NAS: the PVs themselves, and the
# one-shot Jobs that mirror the corpus and the music share onto local disk.
# All three are kept out of Argo and applied by hand.
NAS_UNITS = (
    "-nfs-pv.k8s.yaml",
    "-music-localize.k8s.yaml",
    "-dashcam-localize.k8s.yaml",
)


def _docs(path):
    return [d for d in yaml.safe_load_all(path.read_text()) if d]


def _pod_specs(obj):
    """Every PodSpec anywhere in a manifest, however deeply nested — a CronJob
    buries one two templates down, and an Argo Application can inline one."""
    if isinstance(obj, dict):
        if isinstance(obj.get("containers"), list):
            yield obj
        for v in obj.values():
            yield from _pod_specs(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _pod_specs(v)


def _manifests():
    return sorted(DIST.glob("*.k8s.yaml"))


def _stream_path_manifests():
    return [p for p in _manifests() if not p.name.endswith(NAS_UNITS)]


def _nfs_claims():
    """Claim names bound to an NFS PV, derived rather than hardcoded so a new
    NFS volume extends the guard on its own."""
    pvs, claims = set(), set()
    for path in _manifests():
        for doc in _docs(path):
            if doc.get("kind") == "PersistentVolume" and "nfs" in doc.get("spec", {}):
                pvs.add(doc["metadata"]["name"])
    for path in _manifests():
        for doc in _docs(path):
            if doc.get("kind") == "PersistentVolumeClaim":
                if doc.get("spec", {}).get("volumeName") in pvs:
                    claims.add(doc["metadata"]["name"])
    assert pvs, "no NFS PersistentVolume in dist/ — the claim derivation is vacuous"
    assert claims, "no PVC binds an NFS PV — the claim check would pass on anything"
    return claims


def test_there_are_manifests_to_check():
    # A glob that matches nothing makes every assertion below vacuously true.
    assert _stream_path_manifests(), (
        f"no manifests under {DIST} — run `task cdk8s:synth`"
    )


def test_stream_path_pods_are_inspected():
    total = sum(
        len(list(_pod_specs(d))) for p in _stream_path_manifests() for d in _docs(p)
    )
    assert total, (
        "no pod specs found outside the NAS units — the volume check is vacuous"
    )


def test_no_stream_path_pod_mounts_nfs():
    claims = _nfs_claims()
    offenders = []
    for path in _stream_path_manifests():
        for doc in _docs(path):
            for spec in _pod_specs(doc):
                for vol in spec.get("volumes") or []:
                    name = vol.get("persistentVolumeClaim", {}).get("claimName")
                    if "nfs" in vol:
                        offenders.append(
                            f"{path.name}: inline nfs volume {vol['name']!r}"
                        )
                    elif name in claims:
                        offenders.append(
                            f"{path.name}: volume {vol['name']!r} claims {name!r}"
                        )
    assert not offenders, "NAS-backed volumes in the stream path:\n  " + "\n  ".join(
        offenders
    )


def test_the_nas_units_are_the_ones_that_mount_nfs():
    """The allowlist earns its exemption — if a unit named there stops touching
    the NAS it should leave the list, not sit there widening the hole."""
    for path in _manifests():
        if not path.name.endswith(NAS_UNITS):
            continue
        text = path.read_text()
        assert "nfs:" in text, (
            f"{path.name} is allowlisted for NAS access but mounts none"
        )
