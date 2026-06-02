"""DashcamCV construct tests: the four flat objects (PriorityClass, models PVC,
fill CronJob, one-shot Job) and their load-bearing fields (schedule, suspend,
priority value, PVC size, preemptible pod wiring)."""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.dashcam_cv import DashcamCV


def _synth(env_name="stage-1"):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    DashcamCV(chart, env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def test_emits_four_objects():
    objs = _synth()
    assert _by(objs, "PriorityClass", "dashcam-cv-low")
    assert _by(objs, "PersistentVolumeClaim", "dashcam-cv-models")
    assert _by(objs, "CronJob", "dashcam-cv-fill")
    assert _by(objs, "Job", "dashcam-cv-fill-once")


def test_priorityclass_value_and_not_global_default():
    pc = _by(_synth(), "PriorityClass", "dashcam-cv-low")[0]
    assert pc["value"] == -10
    assert pc["globalDefault"] is False
    assert "preemptible" in pc["description"]


def test_models_pvc_size_and_storageclass():
    pvc = _by(_synth(), "PersistentVolumeClaim", "dashcam-cv-models")[0]
    assert pvc["spec"]["accessModes"] == ["ReadWriteOnce"]
    assert pvc["spec"]["storageClassName"] == "local-path"
    assert pvc["spec"]["resources"]["requests"]["storage"] == "8Gi"


def test_cronjob_schedule_suspend_and_policy():
    cj = _by(_synth(), "CronJob", "dashcam-cv-fill")[0]["spec"]
    assert cj["schedule"] == "*/30 * * * *"
    assert cj["suspend"] is True
    assert cj["concurrencyPolicy"] == "Forbid"
    assert cj["startingDeadlineSeconds"] == 120
    assert cj["successfulJobsHistoryLimit"] == 3
    assert cj["failedJobsHistoryLimit"] == 3
    jobspec = cj["jobTemplate"]["spec"]
    assert jobspec["backoffLimit"] == 0
    assert jobspec["ttlSecondsAfterFinished"] == 3600


def test_cronjob_pod_is_preemptible_and_mounts():
    pod = _by(_synth(), "CronJob", "dashcam-cv-fill")[0]["spec"]["jobTemplate"]["spec"][
        "template"
    ]["spec"]
    assert pod["restartPolicy"] == "Never"
    assert pod["priorityClassName"] == "dashcam-cv-low"
    # wait-for-postgres init container
    assert pod["initContainers"][0]["name"] == "wait-for-postgres"
    embed = pod["containers"][0]
    assert embed["args"] == ["embed", "--random", "3", "--interval", "5", "--apply"]
    assert embed["image"] == "adanalife/dashcam-cv:develop"  # stage image_tag
    assert {m["name"] for m in embed["volumeMounts"]} == {"dashcam", "models"}
    assert embed["env"][0] == {
        "name": "DASHCAM_CV_CORPUS_DIR",
        "value": "/opt/data/Dashcam/_all",
    }
    # envFrom: tripbot-config CM + tripbot-database-creds Secret
    cms = {e["configMapRef"]["name"] for e in embed["envFrom"] if "configMapRef" in e}
    secs = {e["secretRef"]["name"] for e in embed["envFrom"] if "secretRef" in e}
    assert cms == {"tripbot-config"}
    assert secs == {"tripbot-database-creds"}
    claims = {v["persistentVolumeClaim"]["claimName"] for v in pod["volumes"]}
    assert claims == {"vlc-dashcam", "dashcam-cv-models"}


def test_oneshot_job_uses_random_one():
    job = _by(_synth(), "Job", "dashcam-cv-fill-once")[0]["spec"]
    assert job["backoffLimit"] == 0
    assert job["ttlSecondsAfterFinished"] == 3600
    embed = job["template"]["spec"]["containers"][0]
    assert embed["args"] == ["embed", "--random", "1", "--interval", "5", "--apply"]


def test_resources_cpu_cap_and_memory():
    embed = _by(_synth(), "Job", "dashcam-cv-fill-once")[0]["spec"]["template"]["spec"][
        "containers"
    ][0]
    res = embed["resources"]
    assert res["requests"] == {"cpu": "1", "memory": "5Gi"}
    assert res["limits"] == {"cpu": "4", "memory": "6Gi"}


def test_namespace_threaded_from_env():
    objs = _synth("stage-1")
    cj = _by(objs, "CronJob", "dashcam-cv-fill")[0]
    assert cj["metadata"]["namespace"] == "stage-1"
    # PriorityClass is cluster-scoped — no namespace.
    pc = _by(objs, "PriorityClass", "dashcam-cv-low")[0]
    assert "namespace" not in pc["metadata"]
