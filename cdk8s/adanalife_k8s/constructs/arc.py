"""Actions Runner Controller (ARC) supporting resources — the non-Helm objects
the ARC charts need in place before they run.

ARC itself ships as two OCI Helm charts (gha-runner-scale-set-controller +
gha-runner-scale-set), delivered like every other platform component via
helm_platform.cluster_components (Argo Applications on the minipc; see
k8s/arc/*/values.yml for the release config).

What *is* synthesized here (offline, deterministic, golden-gated) is the small
set of namespaced objects ARC depends on, delivered as a cluster-singleton
deploy unit (dist/arc.k8s.yaml), the same shape as the UPS monitor:

  * Two namespaces — `arc-systems` (controller) + `arc-runners` (the runner
    pods + scale set). Owned here rather than via the appset's
    CreateNamespace=true because arc-runners carries PodSecurity labels a bare
    namespace-create can't set.
  * A LimitRange on `arc-runners` so a build burst can't starve the prod
    streams co-tenanting the minipc.
  * The GitHub App credential ExternalSecret (`arc-github-app`) the runner
    scale set authenticates with. Platform components read the cluster-scoped
    `aws-parameterstore-cluster` store (per k8s-platform-stack), so no per-ns
    eso-aws-credentials bootstrap is needed.
  * A CronJob reaping abandoned runner job workspaces off the T5.
  * A read-only Role + RoleBinding letting each env's tripbot-console read the
    scale sets, for its runner panel — the same shape as the console's Argo and
    Burrito grants, and here for the same reason (the namespace is infra's).

minipc-only: the runners serve the private repos' CI and there's exactly one
runner host; the k3d dev cluster doesn't deliver this unit (arc=False).
"""

from __future__ import annotations

import cdk8s
import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.eso import external_secret

SYSTEMS_NS = "arc-systems"
RUNNERS_NS = "arc-runners"
# Parent of the per-pod job workspaces (k8s/arc/runners/values.yml mounts this
# hostPath with subPathExpr: $(POD_NAME)). On the T5, deliberately: /var is the
# volume etcd fsyncs to and a CI write burst there stalls its lease.
WORK_ROOT = "/var/mnt/data/arc-work"
# Comfortably past the 30-minute timeout every fleet workflow sets, so the
# reaper can never delete a workspace out from under a running job.
WORK_REAP_AGE_MINUTES = 120

# The consoles that read the runner pools (tripbot-console's runner panel): one
# console per env, both on this cluster, both watching the same runner scale
# sets. Namespace == env name, as everywhere else.
CONSOLE_ENVS = ("prod-1", "stage-1")

# The materialized Secret the gha-runner-scale-set chart authenticates with
# (githubConfigSecret). Holds the GitHub App triple — keys must be exactly
# github_app_id / github_app_installation_id / github_app_private_key for ARC.
GITHUB_APP_SECRET = "arc-github-app"
# SSM parameter holding that triple as a flat JSON object (dataFrom.extract
# pulls every key verbatim). Lives in the account the cluster store reads.
GITHUB_APP_SM_KEY = "/k8s/arc/github-app"

# Platform components read the cluster-scoped store, not a per-namespace one.
CLUSTER_STORE = ("aws-parameterstore-cluster", "ClusterSecretStore")
# The reaper needs `find` and `rm` and nothing else. Reusing the ubuntu mirror
# the postgres backup already pulls keeps this to zero new mirrored packages
# (each one costs two manual UI clicks to set up)
# and the layers are already on the node.
REAPER_IMAGE = "ghcr.io/adanalife/mirror/ubuntu:24.04"


class Arc(Construct):
    def __init__(self, scope: Construct, id: str = "arc"):
        super().__init__(scope, id)

        # arc-runners hosts the runner pods, which mount hostPath volumes (the
        # shared toolchain caches and the per-pod job workspace) that the
        # cluster-wide PodSecurity `baseline` Talos enforces would reject — so
        # label the namespace `privileged` to exempt it (same escape hatch as
        # local-path-storage / monitoring-host). The
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

        # Guard the shared node: give any container in arc-runners that declares
        # no resources a small default request and limit. A LimitRange (not a
        # ResourceQuota) because a CPU/memory quota rejects any pod whose
        # containers don't all set requests+limits; the LimitRange supplies
        # them instead. maxRunners in the chart values bounds concurrency, and
        # priorityClassName: ci-low makes the runner pods the first eviction
        # victims under node pressure.
        #
        # The pool runs no dind (no containerMode — see the runners values
        # file), so the runner container's own honest request (2.5Gi; peak
        # measured at 1463 MiB across 112 pods on 2026-08-23) is the pod's
        # whole budget and the number to revisit maxRunners against. The only
        # container that reaches these defaults is the chown-caches init
        # container, a mkdir + chown; an init container's request is maxed
        # against the runner's, never added to it, so these numbers don't move
        # the scheduler. They are sized for that job and the workspace reaper:
        # a future container added with no resources gets a 128Mi limit and
        # fails loudly instead of silently borrowing a build-sized budget.
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
                            "defaultRequest": {"cpu": "10m", "memory": "32Mi"},
                            "default": {"cpu": "200m", "memory": "128Mi"},
                        }
                    ]
                },
            )
        )

        # GitHub App creds for runner registration. dataFrom.extract spreads
        # the SM JSON's keys (github_app_id, github_app_installation_id,
        # github_app_private_key) into the Secret.
        external_secret(
            self,
            "github-app",
            name=GITHUB_APP_SECRET,
            namespace=RUNNERS_NS,
            store=CLUSTER_STORE,
            extract=GITHUB_APP_SM_KEY,
        )

        self._workspace_reaper()
        self._console_rbac()

    def _workspace_reaper(self):
        """Delete runner job workspaces whose pod is long gone.

        Each runner pod gets its own subdirectory of WORK_ROOT via
        `subPathExpr: $(POD_NAME)`. That buys first-pass scheduling -- a
        generic ephemeral volume instead deadlocks the scheduler against the
        ephemeral volume controller, costing a random 4-73s per job
        (infra#1194/#1195) -- but a subPath directory outlives its pod, where
        a Delete-reclaim PVC went with it. Verified on the node: the directory
        was still there after the pod was deleted.

        So the cleanup the PVC used to do has to be explicit. Age, not
        pod-liveness, is the predicate: it needs no cluster access, and
        WORK_REAP_AGE_MINUTES is four times the 30-minute timeout every fleet
        workflow sets, so a live job's workspace cannot match.

        `-mindepth 1` is load-bearing -- without it `find` matches WORK_ROOT
        itself and deletes the mount point.
        """
        script = (
            f"find {WORK_ROOT} -mindepth 1 -maxdepth 1 -type d "
            f"-mmin +{WORK_REAP_AGE_MINUTES} -print -exec rm -rf {{}} +"
        )
        k8s.KubeCronJob(
            self,
            "workspace-reaper",
            metadata=k8s.ObjectMeta(name="arc-workspace-reap", namespace=RUNNERS_NS),
            spec=k8s.CronJobSpec(
                schedule="17 * * * *",
                time_zone="Etc/UTC",
                # A second copy would race the first over the same paths.
                concurrency_policy="Forbid",
                successful_jobs_history_limit=1,
                failed_jobs_history_limit=3,
                job_template=k8s.JobTemplateSpec(
                    spec=k8s.JobSpec(
                        backoff_limit=1,
                        ttl_seconds_after_finished=86400,
                        template=k8s.PodTemplateSpec(
                            spec=k8s.PodSpec(
                                restart_policy="Never",
                                # Runs as root (the image default): the
                                # directories are kubelet-created and their
                                # contents are written by uid 1001, so nothing
                                # less can remove both.
                                #
                                # ci-low so the reaper is evicted before any
                                # stage or prod workload — it is pure
                                # housekeeping and the next hour's run catches
                                # whatever this one missed.
                                priority_class_name="ci-low",
                                containers=[
                                    k8s.Container(
                                        name="reap",
                                        image=REAPER_IMAGE,
                                        command=["sh", "-c", script],
                                        volume_mounts=[
                                            k8s.VolumeMount(
                                                name="work-root",
                                                mount_path=WORK_ROOT,
                                            )
                                        ],
                                        resources=k8s.ResourceRequirements(
                                            requests={
                                                "cpu": k8s.Quantity.from_string("10m"),
                                                "memory": k8s.Quantity.from_string(
                                                    "32Mi"
                                                ),
                                            },
                                            limits={
                                                "cpu": k8s.Quantity.from_string("200m"),
                                                "memory": k8s.Quantity.from_string(
                                                    "128Mi"
                                                ),
                                            },
                                        ),
                                    )
                                ],
                                volumes=[
                                    k8s.Volume(
                                        name="work-root",
                                        host_path=k8s.HostPathVolumeSource(
                                            path=WORK_ROOT,
                                            type="DirectoryOrCreate",
                                        ),
                                    )
                                ],
                            )
                        ),
                    )
                ),
            ),
        )

    def _console_rbac(self):
        """A Role + RoleBinding in the runners namespace letting each env's
        `tripbot-console` ServiceAccount read the AutoscalingRunnerSets — the
        console's runner panel, which reports how much self-hosted CI capacity
        is up and how much of it is working. Read-only and scale-sets-only: the
        pool sizes itself off GitHub's job queue, so there is nothing for the
        console to mutate. Mirrors the console's Argo and Burrito grants
        (argocd.py _console_argo_rbac, burrito.py _console_rbac), which the
        console can no more self-grant than this one — its AppProject permits
        only its own app and data namespaces, and this one is infra's.
        """
        name = "tripbot-console-arc"
        k8s.KubeRole(
            self,
            "console-role",
            metadata=k8s.ObjectMeta(name=name, namespace=RUNNERS_NS),
            rules=[
                k8s.PolicyRule(
                    api_groups=["actions.github.com"],
                    resources=["autoscalingrunnersets"],
                    verbs=["get", "list", "watch"],
                )
            ],
        )
        k8s.KubeRoleBinding(
            self,
            "console-rolebinding",
            metadata=k8s.ObjectMeta(name=name, namespace=RUNNERS_NS),
            role_ref=k8s.RoleRef(
                api_group="rbac.authorization.k8s.io", kind="Role", name=name
            ),
            subjects=[
                k8s.Subject(
                    kind="ServiceAccount", name="tripbot-console", namespace=env
                )
                for env in CONSOLE_ENVS
            ],
        )
