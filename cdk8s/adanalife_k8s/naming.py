"""Label / selector / annotation helpers — one place for the label convention
the Kustomize bases established via `labels: [{includeSelectors: false, pairs:
{...}}]`, plus the config-hash stamp that ties a pod template to its ConfigMap.

That kustomize idiom produces two distinct label sets, which the reference
render makes precise:

  * **metadata labels** (every object) = the `app.kubernetes.io/*` pairs ONLY —
    `includeSelectors: false` keeps the `app:` selector label out of metadata.
  * **selector / pod-template labels** = `app: <name>` ONLY (the base's own
    `spec.selector.matchLabels` + `template.metadata.labels`).

Matching these exactly matters: the Service selector and the Deployment
`matchLabels` are immutable join keys, so a re-apply that changed them would
orphan the running pods. Constructs pass `meta_labels(...)` to every
`metadata.labels` and `selector(...)` to selectors + pod templates.
"""

from __future__ import annotations

import hashlib
import json

# Pod-template annotation carrying a digest of the ConfigMap the pod consumes.
# Matches the key the playout repo stamps, so the fleet reads one annotation.
CONFIG_HASH_ANNOTATION = "adanalife.dev/config-hash"


def meta_labels(name: str, *, part_of: str = "tripbot") -> dict[str, str]:
    """The `app.kubernetes.io/*` metadata pair kustomize stamped on all objects."""
    return {
        "app.kubernetes.io/name": name,
        "app.kubernetes.io/part-of": part_of,
    }


def selector(name: str) -> dict[str, str]:
    """The `app` label a Service/Deployment selects on, and that pods carry."""
    return {"app": name}


def config_hash(data: dict[str, str]) -> str:
    """Digest of a ConfigMap's data, for the pod template that consumes it.

    A ConfigMap-only edit leaves the pod template byte-identical, so the
    Deployment does not roll and the change lands nowhere: a subPath mount
    never updates in place, and even a directory mount only reaches a process
    that re-reads its config. Stamping this digest on the template makes the
    config part of the template, so the workload rolls on sync.
    """
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()[:10]
