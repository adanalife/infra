"""VlcServer construct tests: dashcam modes, GPU, ingress/TLS, the prod-only
in-pod onscreens :8081 re-exposure, and config block per env."""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.vlc import (
    VlcServer,
    emit_dashcam_pv,
    emit_dashcam_pvc,
)


def _synth(env_name):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    VlcServer(chart, "twitch", env=load_env(env_name))
    return K8sTesting.synth(chart)


def _synth_emit(fn, env_name):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    fn(chart, load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def test_stage_dashcam_mount_references_pvc_by_name():
    # The PV/PVC are NOT emitted by VlcServer anymore (they're in DataChart);
    # the Deployment just references the PVC by name.
    objs = _synth("stage-1")
    assert not _by(objs, "PersistentVolume", "vlc-dashcam-nfs-stage")
    assert not _by(objs, "PersistentVolumeClaim", "vlc-dashcam")
    dep = _by(objs, "Deployment", "vlc-twitch")[0]
    vol = dep["spec"]["template"]["spec"]["volumes"][0]
    assert vol["persistentVolumeClaim"]["claimName"] == "vlc-dashcam"


def test_dashcam_pvc_is_argo_managed_without_the_pv():
    # The PVC is the Argo-managed half (DataChart). It binds by name to the
    # out-of-band PV and must NOT carry the PV itself — that's DashcamPVChart,
    # deliberately outside Argo.
    objs = _synth_emit(emit_dashcam_pvc, "stage-1")
    pvc = _by(objs, "PersistentVolumeClaim", "vlc-dashcam")[0]
    assert pvc["spec"]["volumeName"] == "vlc-dashcam-nfs-stage"
    assert pvc["spec"]["storageClassName"] == ""
    assert not _by(objs, "PersistentVolume", "vlc-dashcam-nfs-stage")
    # hostPath envs emit nothing (the volume is inline in the Deployment).
    assert not _synth_emit(emit_dashcam_pvc, "local")


def test_dashcam_pv_is_its_own_cluster_scoped_unit():
    import os

    os.environ.setdefault("NFS_SERVER", "10.0.0.5")
    os.environ.setdefault("NFS_PATH", "/export/dashcam")
    # The PV is the out-of-Argo half. Stage gets its OWN PV name (PVs bind 1:1)
    # though it shares prod's export read-only.
    objs = _synth_emit(emit_dashcam_pv, "stage-1")
    pv = _by(objs, "PersistentVolume", "vlc-dashcam-nfs-stage")[0]
    assert (
        pv["spec"]["persistentVolumeReclaimPolicy"] == "Retain"
    )  # data survives deletion
    assert pv["spec"]["nfs"]["readOnly"] is True
    assert "namespace" not in pv["metadata"]  # cluster-scoped
    # PV-only unit — the PVC lives elsewhere (DataChart).
    assert not _by(objs, "PersistentVolumeClaim", "vlc-dashcam")
    # hostPath envs emit nothing.
    assert not _synth_emit(emit_dashcam_pv, "local")


def test_local_uses_hostpath_and_host_access_service():
    objs = _synth("local")
    dep = _by(objs, "Deployment", "vlc-twitch")[0]
    vol = dep["spec"]["template"]["spec"]["volumes"][0]
    assert vol["hostPath"]["path"] == "/host/dashcam"
    assert not _by(objs, "PersistentVolume", "vlc-dashcam-nfs")
    # k3d host-access LoadBalancer only on local.
    assert _by(objs, "Service", "vlc-twitch-host")


def test_gpu_only_on_gpu_envs():
    prod = _by(_synth("prod-1"), "Deployment", "vlc-twitch")[0]
    reqs = prod["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"]
    assert reqs.get("gpu.intel.com/i915") == "1"
    local = _by(_synth("local"), "Deployment", "vlc-twitch")[0]
    lreqs = local["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"]
    assert "gpu.intel.com/i915" not in lreqs


def test_prod_vlc_no_inpod_onscreens_port_but_has_nats():
    # The in-pod onscreens :8081 is decommissioned — no env re-exposes it; prod
    # still carries NATS_URL (its own command subscriber, not the old onscreens).
    objs = _synth("prod-1")
    dep = _by(objs, "Deployment", "vlc-twitch")[0]
    port_names = {
        p["name"] for p in dep["spec"]["template"]["spec"]["containers"][0]["ports"]
    }
    assert "onscreens" not in port_names
    svc_ports = {
        p["name"] for p in _by(objs, "Service", "vlc-twitch")[0]["spec"]["ports"]
    }
    assert "onscreens" not in svc_ports
    cm = _by(objs, "ConfigMap", "vlc-twitch-config")[0]["data"]
    assert cm["NATS_URL"].startswith("nats://")


def test_config_blocks_per_env():
    # local + dev carry the stub block; stage + prod don't.
    assert (
        "DATABASE_USER"
        in _by(_synth("local"), "ConfigMap", "vlc-twitch-config")[0]["data"]
    )
    assert (
        "DATABASE_USER"
        in _by(_synth("development"), "ConfigMap", "vlc-twitch-config")[0]["data"]
    )
    assert (
        "DATABASE_USER"
        not in _by(_synth("stage-1"), "ConfigMap", "vlc-twitch-config")[0]["data"]
    )
    prod_cm = _by(_synth("prod-1"), "ConfigMap", "vlc-twitch-config")[0]["data"]
    assert prod_cm["ENV"] == "production"
    assert prod_cm["OTEL_SDK_DISABLED"] == "false"


def test_ingress_tls_on_minipc_only():
    stage_ing = _by(_synth("stage-1"), "Ingress", "vlc-twitch")[0]
    assert stage_ing["spec"]["tls"][0]["secretName"] == "vlc-twitch-tls"
    assert (
        stage_ing["metadata"]["annotations"]["cert-manager.io/issuer"]
        == "letsencrypt-route53"
    )
    dev_ing = _by(_synth("development"), "Ingress", "vlc-twitch")[0]
    assert "tls" not in dev_ing["spec"] or not dev_ing["spec"]["tls"]
    assert not _by(_synth("local"), "Ingress", "vlc-twitch")
