"""DashcamCV — the incremental dashcam corpus embedder (SigLIP2 → frame_embeddings).

Reproduces the FLAT k8s/apps/dashcam-cv/* manifests (no base/overlays, NOT in any
env umbrella — applied via its own task, currently stage-only with `-n stage-1`),
split into two deploy units so a normal apply never re-runs the one-shot Jobs:

`DashcamCV` (PERSISTENT — dist/dashcam-cv.k8s.yaml, applied on `task k8s:<env>:dashcam-cv`):
  * PriorityClass `dashcam-cv-low` (value -10): cluster-scoped, below every
    default-priority pod so the scheduler preempts THIS job, never the live stream.
  * PersistentVolumeClaim `dashcam-cv-models` (8Gi, local-path): persistent HF_HOME
    cache for the ~4.4 GB so400m checkpoint, reused across runs.
  * CronJob `dashcam-cv-fill` (*/20, suspended): the incremental fill. Ships
    SUSPENDED — the manual fill-job ramp comes first, then unsuspend. Each tick
    runs 2 pods (parallelism/completions 2), each embedding `--random 10`.

`DashcamCVJobs` (ON-DEMAND — dist/dashcam-cv-jobs.k8s.yaml, run via per-job tasks):
  * Job `dashcam-cv-fill-once`: the one-shot manual ramp pod (same embed container,
    `--random 1`).
  * Job `dashcam-cv-find` / `dashcam-cv-stats`: read-only ops one-offs (corpus
    search / coverage+stats). Same hardened pod, no corpus mount or postgres-wait.

All pods run under the restricted Pod Security Standard stage-1 enforces: pod-level
runAsNonRoot/65532 + fsGroup (so UID 65532 can write the model-cache PVC) + seccomp
RuntimeDefault, and per-container allowPrivilegeEscalation:false + drop ALL caps.
`HOME`/`USER` are set because UID 65532 has no /etc/passwd entry and torch's
getpass.getuser() raises at import without them.

The pod is shared by all four workloads via `_pod_spec` — `with_corpus` toggles the
wait-for-postgres init + the (read-only) dashcam corpus mount + DASHCAM_CV_CORPUS_DIR
(embed needs them; find/stats don't). DB config comes from the stable
`tripbot-config` ConfigMap + `tripbot-database-creds` Secret.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.naming import meta_labels

NAME = "dashcam-cv"
IMAGE = "adanalife/dashcam-cv"  # tag from env.image_tag (develop on stage)
PRIORITY_CLASS = "dashcam-cv-low"
CORPUS_DIR = "/opt/data/Dashcam/_all"  # DASHCAM_CV_CORPUS_DIR + dashcam mount path
MODELS_DIR = "/opt/models"  # HF_HOME (baked in the image)

# stage-1 enforces the restricted Pod Security Standard. Pod runs as nonroot UID
# 65532 with a default seccomp profile; fsGroup 65532 lets that UID write the
# model-cache PVC. (Ported from k8s/apps/dashcam-cv/*; both must stay in sync.)
_POD_SECURITY_CONTEXT = k8s.PodSecurityContext(
    run_as_non_root=True,
    run_as_user=65532,
    run_as_group=65532,
    fs_group=65532,
    seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault"),
)
_CONTAINER_SECURITY_CONTEXT = k8s.SecurityContext(
    allow_privilege_escalation=False,
    capabilities=k8s.Capabilities(drop=["ALL"]),
)


class DashcamCV(Construct):
    """The PERSISTENT dashcam-cv fill workload — PriorityClass + models PVC +
    the (suspended) fill CronJob. Applied via `task k8s:<env>:dashcam-cv` on a
    normal apply. The one-shot ops Jobs (fill-once / find / stats) live in
    DashcamCVJobs so they don't re-run on every apply (same split as tripbot's
    JobsChart)."""

    def __init__(self, scope: Construct, *, env: EnvConfig):
        super().__init__(scope, NAME)
        ns = env.namespace or None
        image = f"{IMAGE}:{env.image_tag}"  # adanalife/dashcam-cv:develop on stage
        labels = meta_labels(NAME)

        # --- PriorityClass (cluster-scoped; no namespace) ---
        # value < 0 → every default-priority (0) pod outranks the embed job, so it
        # gets preempted under pressure and never displaces the live stream.
        k8s.KubePriorityClass(
            self,
            "priorityclass",
            metadata=k8s.ObjectMeta(name=PRIORITY_CLASS, labels=labels),
            value=-10,
            global_default=False,
            description="Background dashcam-cv embedding — preemptible; never outranks live workloads.",
        )

        # --- models cache PVC (persistent HF_HOME, local-path) ---
        k8s.KubePersistentVolumeClaim(
            self,
            "models-pvc",
            metadata=k8s.ObjectMeta(
                name="dashcam-cv-models", namespace=ns, labels=labels
            ),
            spec=k8s.PersistentVolumeClaimSpec(
                access_modes=["ReadWriteOnce"],
                storage_class_name="local-path",
                resources=k8s.ResourceRequirements(
                    requests={"storage": k8s.Quantity.from_string("8Gi")}
                ),
            ),
        )

        # --- CronJob: incremental fill (suspended; */20, 2 pods/run) ---
        # backoffLimit 0 + restartPolicy Never: a failed run isn't retried (the next
        # tick picks up where it left off). ttl reaps finished pods after an hour.
        # parallelism/completions 2 → ~20 videos/tick; ON CONFLICT DO NOTHING dedupes
        # any overlap between the two independent random picks.
        k8s.KubeCronJob(
            self,
            "fill-cronjob",
            metadata=k8s.ObjectMeta(
                name="dashcam-cv-fill", namespace=ns, labels=labels
            ),
            spec=k8s.CronJobSpec(
                schedule="*/20 * * * *",
                suspend=True,  # safety: enable only after the manual ramp
                concurrency_policy="Forbid",  # never overlap runs
                starting_deadline_seconds=120,
                successful_jobs_history_limit=3,
                failed_jobs_history_limit=3,
                job_template=k8s.JobTemplateSpec(
                    spec=k8s.JobSpec(
                        parallelism=2,
                        completions=2,
                        backoff_limit=0,
                        ttl_seconds_after_finished=3600,
                        template=_pod_spec(
                            image,
                            container_name="embed",
                            args=[
                                "embed",
                                "--random",
                                "10",
                                "--interval",
                                "5",
                                "--apply",
                            ],
                            with_corpus=True,
                        ),
                    )
                ),
            ),
        )


class DashcamCVJobs(Construct):
    """The ON-DEMAND dashcam-cv one-shot Jobs — fill-once (manual ramp), find
    (corpus search) and stats (coverage scan). Their own deploy unit so they
    don't re-run on every `apply` of the persistent fill workload (running a
    Job on each reconcile would be wrong). They depend on DashcamCV's models
    PVC + PriorityClass, so apply that first. Run via the per-job tasks."""

    def __init__(self, scope: Construct, *, env: EnvConfig):
        super().__init__(scope, f"{NAME}-jobs")
        ns = env.namespace or None
        image = f"{IMAGE}:{env.image_tag}"
        labels = meta_labels(NAME)

        # --- Job: one-shot manual ramp (same embed pod, --random 1) ---
        k8s.KubeJob(
            self,
            "fill-job",
            metadata=k8s.ObjectMeta(
                name="dashcam-cv-fill-once", namespace=ns, labels=labels
            ),
            spec=k8s.JobSpec(
                backoff_limit=0,
                ttl_seconds_after_finished=3600,
                template=_pod_spec(
                    image,
                    container_name="embed",
                    args=["embed", "--random", "1", "--interval", "5", "--apply"],
                    with_corpus=True,
                ),
            ),
        )

        # --- Job: find (read-only corpus search; no corpus mount / postgres-wait) ---
        k8s.KubeJob(
            self,
            "find-job",
            metadata=k8s.ObjectMeta(
                name="dashcam-cv-find", namespace=ns, labels=labels
            ),
            spec=k8s.JobSpec(
                backoff_limit=0,
                ttl_seconds_after_finished=3600,
                template=_pod_spec(
                    image,
                    container_name="find",
                    args=["find", "a road with trees", "-k", "5"],
                    with_corpus=False,
                ),
            ),
        )

        # --- Job: stats (read-only coverage + concept scan) ---
        k8s.KubeJob(
            self,
            "stats-job",
            metadata=k8s.ObjectMeta(
                name="dashcam-cv-stats", namespace=ns, labels=labels
            ),
            spec=k8s.JobSpec(
                backoff_limit=0,
                ttl_seconds_after_finished=3600,
                template=_pod_spec(
                    image,
                    container_name="stats",
                    args=["stats", "--concepts"],
                    with_corpus=False,
                ),
            ),
        )


def _pod_spec(
    image: str, *, container_name: str, args: list[str], with_corpus: bool
) -> k8s.PodTemplateSpec:
    """The hardened dashcam-cv pod, shared by all four workloads. `with_corpus`
    adds the wait-for-postgres init + the read-only dashcam corpus mount +
    DASHCAM_CV_CORPUS_DIR (embed needs them; the find/stats query pods don't).
    Preemptible under dashcam-cv-low; always mounts the models cache PVC."""
    init_containers = None
    env = []
    volume_mounts = []
    volumes = []

    if with_corpus:
        init_containers = [
            k8s.Container(
                name="wait-for-postgres",
                image="busybox:1.36",
                command=[
                    "sh",
                    "-c",
                    "until nc -z postgres 5432; do echo waiting; sleep 2; done",
                ],
                security_context=_CONTAINER_SECURITY_CONTEXT,
            )
        ]
        env.append(k8s.EnvVar(name="DASHCAM_CV_CORPUS_DIR", value=CORPUS_DIR))
        volume_mounts.append(
            k8s.VolumeMount(name="dashcam", mount_path=CORPUS_DIR, read_only=True)
        )
        volumes.append(
            k8s.Volume(
                name="dashcam",
                persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                    claim_name="vlc-dashcam"
                ),
            )  # stage NFS corpus, ro
        )

    # UID 65532 has no home dir / passwd entry; torch's getpass.getuser() needs
    # $USER set or it raises at import.
    env += [
        k8s.EnvVar(name="HOME", value="/tmp"),
        k8s.EnvVar(name="USER", value="dashcam"),
    ]
    volume_mounts.append(k8s.VolumeMount(name="models", mount_path=MODELS_DIR))
    volumes.append(
        k8s.Volume(
            name="models",
            persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                claim_name="dashcam-cv-models"
            ),
        )
    )

    return k8s.PodTemplateSpec(
        spec=k8s.PodSpec(
            restart_policy="Never",
            priority_class_name=PRIORITY_CLASS,
            security_context=_POD_SECURITY_CONTEXT,
            init_containers=init_containers,
            containers=[
                k8s.Container(
                    name=container_name,
                    image=image,
                    image_pull_policy="Always",
                    args=args,
                    security_context=_CONTAINER_SECURITY_CONTEXT,
                    env_from=[
                        k8s.EnvFromSource(
                            config_map_ref=k8s.ConfigMapEnvSource(name="tripbot-config")
                        ),
                        k8s.EnvFromSource(
                            secret_ref=k8s.SecretEnvSource(
                                name="tripbot-database-creds"
                            )
                        ),
                    ],
                    env=env,
                    resources=k8s.ResourceRequirements(
                        requests={
                            "cpu": k8s.Quantity.from_string("1"),
                            "memory": k8s.Quantity.from_string("5Gi"),
                        },
                        limits={
                            "cpu": k8s.Quantity.from_string(
                                "4"
                            ),  # hard CPU cap so prod keeps its cores
                            "memory": k8s.Quantity.from_string("6Gi"),
                        },
                    ),
                    volume_mounts=volume_mounts,
                )
            ],
            volumes=volumes,
        )
    )
