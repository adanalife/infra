"""Label / selector helpers — one place for the label convention the Kustomize
bases established via `labels: [{includeSelectors: false, pairs: {...}}]`.

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


def meta_labels(name: str, *, part_of: str = "tripbot") -> dict[str, str]:
    """The `app.kubernetes.io/*` metadata pair kustomize stamped on all objects."""
    return {
        "app.kubernetes.io/name": name,
        "app.kubernetes.io/part-of": part_of,
    }


def selector(name: str) -> dict[str, str]:
    """The `app` label a Service/Deployment selects on, and that pods carry."""
    return {"app": name}
