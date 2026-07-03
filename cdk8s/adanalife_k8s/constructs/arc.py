"""Actions Runner Controller (ARC) supporting resources — the non-Helm objects
the ARC charts need in place before they run.

ARC itself ships as two OCI Helm charts (gha-runner-scale-set-controller +
gha-runner-scale-set), delivered as Argo Applications in the platform stack
(see helm_platform.arc_components / argo_platform.ArgoPlatform). cdk8s can't
`helm template` an OCI chart, so the charts are Argo-rendered in-cluster, not
synthesized here.

What *is* synthesized here (offline, deterministic, golden-gated) is the small
set of namespaced objects ARC depends on, delivered as a cluster-singleton
deploy unit (dist/arc.k8s.yaml), the same shape as the UPS monitor:

  * Two namespaces — `arc-systems` (controller) + `arc-runners` (the runner
    pods + scale set). Owned here so the unit is self-sufficient; the Helm
    Applications' CreateNamespace=true is then a harmless no-op.
  * A ResourceQuota on `arc-runners` so a build burst on the shared rpi5 can't
    starve the stage-1 workloads co-tenanting the node.
  * The GitHub App credential ExternalSecret (`arc-github-app`) the runner scale
    set authenticates with. Platform components read the cluster-scoped
    `aws-parameterstore-cluster` store (per k8s-platform-stack), so no per-ns
    eso-aws-credentials bootstrap is needed.

minipc-only: the Pi is an arm64 worker on the minipc Talos cluster; the k3d dev
cluster has no Pi, so the dev Argo doesn't deliver this unit (arc=False).
"""

from __future__ import annotations

import cdk8s
from constructs import Construct

from adanalife_k8s.eso import external_secret

SYSTEMS_NS = "arc-systems"
RUNNERS_NS = "arc-runners"

# The materialized Secret the gha-runner-scale-set chart authenticates with
# (githubConfigSecret). Holds the GitHub App triple — keys must be exactly
# github_app_id / github_app_installation_id / github_app_private_key for ARC.
GITHUB_APP_SECRET = "arc-github-app"
# SSM parameter holding that triple as a flat JSON object (dataFrom.extract
# pulls every key verbatim). Lives in the account the cluster store reads.
GITHUB_APP_SM_KEY = "/k8s/arc/github-app"

# Platform components read the cluster-scoped store, not a per-namespace one.
CLUSTER_STORE = ("aws-parameterstore-cluster", "ClusterSecretStore")


class Arc(Construct):
    def __init__(self, scope: Construct, id: str = "arc"):
        super().__init__(scope, id)

        # arc-runners hosts the runner pods + their dind sidecar (a privileged
        # Docker daemon), which the cluster-wide PodSecurity `baseline` Talos
        # enforces would reject — so label the namespace `privileged` to exempt
        # it (same escape hatch as local-path-storage / monitoring-host). The
        # controller (arc-systems) is an ordinary Deployment, no exemption.
        ns_labels = {
            RUNNERS_NS: {
                "pod-security.kubernetes.io/enforce": "privileged",
                "pod-security.kubernetes.io/warn": "privileged",
            },
        }
        for ns in (SYSTEMS_NS, RUNNERS_NS):
            meta: dict = {"name": ns}
            if ns in ns_labels:
                meta["labels"] = ns_labels[ns]
            cdk8s.ApiObject(
                self,
                f"ns-{ns}",
                api_version="v1",
                kind="Namespace",
                metadata=meta,
            )

        # Guard the shared rpi5: bound each runner container so a build can't
        # OOM/CPU-starve the stage-1 pods on the node. A LimitRange (not a
        # ResourceQuota) is the right tool here — ARC injects `dind` +
        # `init-dind-externals` containers that declare no resources, and a
        # CPU/memory ResourceQuota rejects any pod whose containers don't all set
        # requests+limits. The LimitRange instead *supplies* defaults to those
        # injected containers (and caps per-container memory); maxRunners in the
        # chart values bounds concurrency. dind (where `docker build` actually
        # runs) gets the headroom; the runner agent sits well under the default.
        limits = cdk8s.ApiObject(
            self,
            "runner-limits",
            api_version="v1",
            kind="LimitRange",
            metadata={"name": "arc-runners-limits", "namespace": RUNNERS_NS},
        )
        limits.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "limits": [
                        {
                            "type": "Container",
                            "defaultRequest": {"cpu": "250m", "memory": "512Mi"},
                            "default": {"cpu": "2", "memory": "4Gi"},
                        }
                    ]
                },
            )
        )

        # GitHub App creds for runner registration + the fallback runner-online
        # probe. dataFrom.extract spreads the SM JSON's keys (github_app_id,
        # github_app_installation_id, github_app_private_key) into the Secret.
        external_secret(
            self,
            "github-app",
            name=GITHUB_APP_SECRET,
            namespace=RUNNERS_NS,
            store=CLUSTER_STORE,
            extract=GITHUB_APP_SM_KEY,
        )
