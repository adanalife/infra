"""External Secrets Operator CR builders.

cdk8s *emits the CRs*; ESO does the materialization. The ESO CRDs aren't in
`imports/k8s`, so (like obs.py's stream-key) these go out as `cdk8s.ApiObject`
+ a `/spec` JsonPatch. Three ExternalSecret shapes appear in the legacy
manifests, all covered here:

  1. `dataFrom.extract`  — pull every top-level key of a JSON SM value into the
     Secret (grafana OTLP, sentry, postgres). `extract=<sm key>`.
  2. per-key `remoteRef` + `property` — map specific SM JSON properties to named
     Secret keys (cert-manager creds). `data=[ESData(secret_key, key, property)]`.
  3. bare `remoteRef` — one SM container → one Secret key (obs stream-key).
     `data=[ESData(secret_key, key)]`.

The keybase `eso-aws-credentials` bootstrap is unchanged — cdk8s never creates
it; the SecretStore just references it, exactly as the legacy SecretStore did.
"""
from __future__ import annotations

from dataclasses import dataclass

import cdk8s
from constructs import Construct

from adanalife_k8s.naming import meta_labels

# The store every app ExternalSecret references — namespaced, identical in
# every env (isolation is structural: a namespaced store is unreachable
# cross-namespace; the backing eso-aws-credentials decides the AWS account).
DEFAULT_STORE = ("aws-secretsmanager", "SecretStore")


@dataclass(frozen=True)
class ESData:
    """One entry in an ExternalSecret `spec.data[]`."""
    secret_key: str           # key in the materialized Secret
    key: str                  # SM container path
    property: str | None = None  # JSON property within the SM value (pattern 2)


def secret_store(scope: Construct, id: str = "secret-store", *, namespace: str | None = None):
    """Per-namespace `aws-secretsmanager` SecretStore. Byte-identical across
    envs (the in-namespace eso-aws-credentials routes to the right account)."""
    store = cdk8s.ApiObject(
        scope, id,
        api_version="external-secrets.io/v1", kind="SecretStore",
        metadata={"name": "aws-secretsmanager", **({"namespace": namespace} if namespace else {})},
    )
    store.add_json_patch(cdk8s.JsonPatch.add("/spec", {
        "provider": {"aws": {
            "service": "SecretsManager",
            "region": "us-east-1",
            "auth": {"secretRef": {
                "accessKeyIDSecretRef": {"name": "eso-aws-credentials", "key": "AWS_ACCESS_KEY_ID"},
                "secretAccessKeySecretRef": {"name": "eso-aws-credentials", "key": "AWS_SECRET_ACCESS_KEY"},
            }},
        }},
    }))
    return store


def external_secret(
    scope: Construct,
    id: str,
    *,
    name: str,
    namespace: str | None = None,
    refresh: str = "1h",
    store: tuple[str, str] = DEFAULT_STORE,
    target_name: str | None = None,
    creation_policy: str | None = None,
    labels: dict[str, str] | None = None,
    extract: str | None = None,
    data: list[ESData] | None = None,
):
    """Emit one ExternalSecret. Supply exactly one of `extract` (pattern 1) or
    `data` (patterns 2/3). `target_name` defaults to `name`."""
    if (extract is None) == (data is None):
        raise ValueError("external_secret: pass exactly one of extract= or data=")

    meta: dict = {"name": name}
    if namespace:
        meta["namespace"] = namespace
    if labels:
        meta["labels"] = labels

    target: dict = {"name": target_name or name}
    if creation_policy:
        target["creationPolicy"] = creation_policy

    spec: dict = {
        "refreshInterval": refresh,
        "secretStoreRef": {"name": store[0], "kind": store[1]},
        "target": target,
    }
    if extract is not None:
        spec["dataFrom"] = [{"extract": {"key": extract}}]
    else:
        spec["data"] = [
            {"secretKey": d.secret_key,
             "remoteRef": {"key": d.key, **({"property": d.property} if d.property else {})}}
            for d in data
        ]

    es = cdk8s.ApiObject(scope, id, api_version="external-secrets.io/v1",
                         kind="ExternalSecret", metadata=meta)
    es.add_json_patch(cdk8s.JsonPatch.add("/spec", spec))
    return es
