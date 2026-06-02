"""DashcamCV — the incremental dashcam corpus embedder (SigLIP2 → frame_embeddings).

Reproduces the FLAT k8s/apps/dashcam-cv/* manifests (no base/overlays, NOT in any
env umbrella — applied via its own task, currently stage-only with `-n stage-1`):

  * PriorityClass `dashcam-cv-low` (value -10): cluster-scoped, below every
    default-priority pod so the scheduler preempts THIS job, never the live stream.
  * PersistentVolumeClaim `dashcam-cv-models` (8Gi, local-path): persistent HF_HOME
    cache for the ~4.4 GB so400m checkpoint, reused across runs.
  * CronJob `dashcam-cv-fill` (*/30, suspended): the incremental fill. Ships
    SUSPENDED — the manual fill-job ramp comes first, then unsuspend.
  * Job `dashcam-cv-fill-once`: the one-shot manual ramp pod (same container shape,
    `--random 1` instead of `--random 3`).

The CronJob/Job pod is identical except for `args`, so a shared `_embed_pod_spec`
helper builds both. Both wait-for-postgres, run preemptibly under the low
PriorityClass, mount the (read-only) dashcam corpus PVC + the models cache PVC, and
read DB config from the stable `tripbot-config` ConfigMap + `tripbot-database-creds`
Secret.
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


class DashcamCV(Construct):
    def __init__(self, scope: Construct, *, env: EnvConfig):
        super().__init__(scope, NAME)
        ns = env.namespace or None
        self._image = (
            f"{IMAGE}:{env.image_tag}"  # adanalife/dashcam-cv:develop on stage
        )
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

        # --- CronJob: incremental fill (suspended; */30) ---
        # backoffLimit 0 + restartPolicy Never: a failed run isn't retried (the next
        # tick picks up where it left off). ttl reaps finished pods after an hour.
        k8s.KubeCronJob(
            self,
            "fill-cronjob",
            metadata=k8s.ObjectMeta(
                name="dashcam-cv-fill", namespace=ns, labels=labels
            ),
            spec=k8s.CronJobSpec(
                schedule="*/30 * * * *",
                suspend=True,  # safety: enable only after the manual ramp
                concurrency_policy="Forbid",  # never overlap runs
                starting_deadline_seconds=120,
                successful_jobs_history_limit=3,
                failed_jobs_history_limit=3,
                job_template=k8s.JobTemplateSpec(
                    spec=k8s.JobSpec(
                        backoff_limit=0,
                        ttl_seconds_after_finished=3600,
                        template=self._embed_pod_spec(
                            labels,
                            args=[
                                "embed",
                                "--random",
                                "3",
                                "--interval",
                                "5",
                                "--apply",
                            ],
                        ),
                    )
                ),
            ),
        )

        # --- Job: one-shot manual ramp (same pod, --random 1) ---
        k8s.KubeJob(
            self,
            "fill-job",
            metadata=k8s.ObjectMeta(
                name="dashcam-cv-fill-once", namespace=ns, labels=labels
            ),
            spec=k8s.JobSpec(
                backoff_limit=0,
                ttl_seconds_after_finished=3600,
                template=self._embed_pod_spec(
                    labels,
                    args=["embed", "--random", "1", "--interval", "5", "--apply"],
                ),
            ),
        )

    # ---- helpers ----
    def _embed_pod_spec(self, labels, *, args: list[str]) -> k8s.PodTemplateSpec:
        """The embed pod, shared by the CronJob and the one-shot Job (differ only
        in `args`). wait-for-postgres init, preemptible under dashcam-cv-low,
        dashcam corpus (ro) + models cache mounts."""
        return k8s.PodTemplateSpec(
            spec=k8s.PodSpec(
                restart_policy="Never",
                priority_class_name=PRIORITY_CLASS,
                init_containers=[
                    k8s.Container(
                        name="wait-for-postgres",
                        image="busybox:1.36",
                        command=[
                            "sh",
                            "-c",
                            "until nc -z postgres 5432; do echo waiting; sleep 2; done",
                        ],
                    )
                ],
                containers=[
                    k8s.Container(
                        name="embed",
                        image=self._image,
                        image_pull_policy="Always",
                        args=args,
                        env_from=[
                            k8s.EnvFromSource(
                                config_map_ref=k8s.ConfigMapEnvSource(
                                    name="tripbot-config"
                                )
                            ),
                            k8s.EnvFromSource(
                                secret_ref=k8s.SecretEnvSource(
                                    name="tripbot-database-creds"
                                )
                            ),
                        ],
                        env=[
                            k8s.EnvVar(name="DASHCAM_CV_CORPUS_DIR", value=CORPUS_DIR)
                        ],
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
                        volume_mounts=[
                            k8s.VolumeMount(
                                name="dashcam", mount_path=CORPUS_DIR, read_only=True
                            ),
                            k8s.VolumeMount(name="models", mount_path=MODELS_DIR),
                        ],
                    )
                ],
                volumes=[
                    k8s.Volume(
                        name="dashcam",
                        persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                            claim_name="vlc-dashcam"
                        ),
                    ),  # stage NFS corpus, ro
                    k8s.Volume(
                        name="models",
                        persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                            claim_name="dashcam-cv-models"
                        ),
                    ),
                ],
            )
        )
