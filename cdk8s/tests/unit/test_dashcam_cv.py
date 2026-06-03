"""DashcamCV construct tests: the flat objects (PriorityClass, models PVC, fill
CronJob, one-shot fill Job, find/stats ops Jobs) and their load-bearing fields
(schedule, suspend, parallelism, priority value, PVC size, restricted-PSS
hardening, preemptible pod wiring)."""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.dashcam_cv import DashcamCV, DashcamCVJobs


def _synth(env_name="stage-1"):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    DashcamCV(chart, env=load_env(env_name))
    return K8sTesting.synth(chart)


def _synth_jobs(env_name="stage-1"):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    DashcamCVJobs(chart, env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def test_persistent_unit_emits_no_oneshot_jobs():
    # DashcamCV (the persistent unit applied on every apply) carries only the
    # PriorityClass + models PVC + fill CronJob — NOT the one-shot Jobs.
    objs = _synth()
    assert _by(objs, "PriorityClass", "dashcam-cv-low")
    assert _by(objs, "PersistentVolumeClaim", "dashcam-cv-models")
    assert _by(objs, "CronJob", "dashcam-cv-fill")
    assert not [o for o in objs if o["kind"] == "Job"]


def test_jobs_unit_emits_only_the_oneshot_jobs():
    objs = _synth_jobs()
    assert _by(objs, "Job", "dashcam-cv-fill-once")
    assert _by(objs, "Job", "dashcam-cv-find")
    assert _by(objs, "Job", "dashcam-cv-stats")
    # no persistent resources leak into the jobs unit
    assert not _by(objs, "CronJob", "dashcam-cv-fill")
    assert not _by(objs, "PersistentVolumeClaim", "dashcam-cv-models")


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
    assert cj["schedule"] == "*/20 * * * *"
    assert cj["suspend"] is True
    assert cj["concurrencyPolicy"] == "Forbid"
    assert cj["startingDeadlineSeconds"] == 120
    assert cj["successfulJobsHistoryLimit"] == 3
    assert cj["failedJobsHistoryLimit"] == 3
    jobspec = cj["jobTemplate"]["spec"]
    assert jobspec["backoffLimit"] == 0
    assert jobspec["ttlSecondsAfterFinished"] == 3600
    # 2 pods per tick (~20 videos), Forbid keeps them non-overlapping
    assert jobspec["parallelism"] == 2
    assert jobspec["completions"] == 2


def test_cronjob_pod_is_preemptible_and_mounts():
    pod = _by(_synth(), "CronJob", "dashcam-cv-fill")[0]["spec"]["jobTemplate"]["spec"][
        "template"
    ]["spec"]
    assert pod["restartPolicy"] == "Never"
    assert pod["priorityClassName"] == "dashcam-cv-low"
    # wait-for-postgres init container
    assert pod["initContainers"][0]["name"] == "wait-for-postgres"
    embed = pod["containers"][0]
    assert embed["args"] == ["embed", "--random", "10", "--interval", "5", "--apply"]
    assert embed["image"] == "adanalife/dashcam-cv:develop"  # stage image_tag
    assert {m["name"] for m in embed["volumeMounts"]} == {"dashcam", "models"}
    assert embed["env"][0] == {
        "name": "DASHCAM_CV_CORPUS_DIR",
        "value": "/opt/data/Dashcam/_all",
    }
    # envFrom: the primary platform's tripbot CM + tripbot-database-creds Secret
    cms = {e["configMapRef"]["name"] for e in embed["envFrom"] if "configMapRef" in e}
    secs = {e["secretRef"]["name"] for e in embed["envFrom"] if "secretRef" in e}
    assert cms == {"tripbot-twitch-config"}
    assert secs == {"tripbot-database-creds"}
    claims = {v["persistentVolumeClaim"]["claimName"] for v in pod["volumes"]}
    assert claims == {"vlc-dashcam", "dashcam-cv-models"}


def test_oneshot_job_uses_random_one():
    job = _by(_synth_jobs(), "Job", "dashcam-cv-fill-once")[0]["spec"]
    assert job["backoffLimit"] == 0
    assert job["ttlSecondsAfterFinished"] == 3600
    embed = job["template"]["spec"]["containers"][0]
    assert embed["args"] == ["embed", "--random", "1", "--interval", "5", "--apply"]


def test_resources_cpu_cap_and_memory():
    embed = _by(_synth_jobs(), "Job", "dashcam-cv-fill-once")[0]["spec"]["template"][
        "spec"
    ]["containers"][0]
    res = embed["resources"]
    assert res["requests"] == {"cpu": "1", "memory": "5Gi"}
    assert res["limits"] == {"cpu": "4", "memory": "6Gi"}


def test_pods_satisfy_restricted_pod_security():
    # stage-1 enforces the restricted PSS; every dashcam-cv pod must carry the
    # nonroot/seccomp pod context + drop-ALL container context, or it's rejected.
    objs = _synth()
    jobs = _synth_jobs()
    pods = [
        _by(objs, "CronJob", "dashcam-cv-fill")[0]["spec"]["jobTemplate"]["spec"][
            "template"
        ]["spec"],
        _by(jobs, "Job", "dashcam-cv-fill-once")[0]["spec"]["template"]["spec"],
        _by(jobs, "Job", "dashcam-cv-find")[0]["spec"]["template"]["spec"],
        _by(jobs, "Job", "dashcam-cv-stats")[0]["spec"]["template"]["spec"],
    ]
    for pod in pods:
        sc = pod["securityContext"]
        assert sc["runAsNonRoot"] is True
        assert sc["runAsUser"] == 65532
        assert sc["fsGroup"] == 65532
        assert sc["seccompProfile"]["type"] == "RuntimeDefault"
        # every container (incl. any init) drops all caps + no priv-escalation
        containers = pod["containers"] + pod.get("initContainers", [])
        for c in containers:
            assert c["securityContext"]["allowPrivilegeEscalation"] is False
            assert c["securityContext"]["capabilities"]["drop"] == ["ALL"]
        # HOME/USER set so torch's getpass.getuser() doesn't raise under UID 65532
        app = pod["containers"][0]
        envs = {e["name"]: e["value"] for e in app["env"]}
        assert envs["HOME"] == "/tmp"
        assert envs["USER"] == "dashcam"


def test_find_and_stats_are_query_pods_without_corpus():
    # find/stats are read-only ops one-offs: no wait-for-postgres init, no dashcam
    # corpus mount — just the models cache. Same hardened pod otherwise.
    objs = _synth_jobs()
    for name, args in (
        ("dashcam-cv-find", ["find", "a road with trees", "-k", "5"]),
        ("dashcam-cv-stats", ["stats", "--concepts"]),
    ):
        pod = _by(objs, "Job", name)[0]["spec"]["template"]["spec"]
        assert "initContainers" not in pod
        claims = {v["persistentVolumeClaim"]["claimName"] for v in pod["volumes"]}
        assert claims == {"dashcam-cv-models"}  # no vlc-dashcam corpus
        c = pod["containers"][0]
        assert c["args"] == args
        assert {m["name"] for m in c["volumeMounts"]} == {"models"}


def test_namespace_threaded_from_env():
    objs = _synth("stage-1")
    cj = _by(objs, "CronJob", "dashcam-cv-fill")[0]
    assert cj["metadata"]["namespace"] == "stage-1"
    # PriorityClass is cluster-scoped — no namespace.
    pc = _by(objs, "PriorityClass", "dashcam-cv-low")[0]
    assert "namespace" not in pc["metadata"]
