"""VlcServer construct tests: dashcam modes, GPU, ingress/TLS, the prod-only
in-pod onscreens :8081 re-exposure, and config block per env."""
from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.vlc import VlcServer


def _synth(env_name):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    VlcServer(chart, env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def test_stage_nfs_pv_pvc_and_mount():
    import os
    os.environ.setdefault("NFS_SERVER", "10.0.0.5")
    os.environ.setdefault("NFS_PATH", "/export/dashcam")
    objs = _synth("stage-1")
    # Stage gets its OWN PV name (PVs bind 1:1) though it shares prod's export.
    assert _by(objs, "PersistentVolume", "vlc-dashcam-nfs-stage")
    pvc = _by(objs, "PersistentVolumeClaim", "vlc-dashcam")[0]
    assert pvc["spec"]["volumeName"] == "vlc-dashcam-nfs-stage"
    dep = _by(objs, "Deployment", "vlc-server")[0]
    vol = dep["spec"]["template"]["spec"]["volumes"][0]
    assert vol["persistentVolumeClaim"]["claimName"] == "vlc-dashcam"


def test_local_uses_hostpath_and_host_access_service():
    objs = _synth("local")
    dep = _by(objs, "Deployment", "vlc-server")[0]
    vol = dep["spec"]["template"]["spec"]["volumes"][0]
    assert vol["hostPath"]["path"] == "/host/dashcam"
    assert not _by(objs, "PersistentVolume", "vlc-dashcam-nfs")
    # k3d host-access LoadBalancer only on local.
    assert _by(objs, "Service", "vlc-server-host")


def test_gpu_only_on_gpu_envs():
    prod = _by(_synth("prod-1"), "Deployment", "vlc-server")[0]
    reqs = prod["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"]
    assert reqs.get("gpu.intel.com/i915") == "1"
    local = _by(_synth("local"), "Deployment", "vlc-server")[0]
    lreqs = local["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"]
    assert "gpu.intel.com/i915" not in lreqs


def test_prod_inpod_onscreens_port_and_nats():
    objs = _synth("prod-1")
    dep = _by(objs, "Deployment", "vlc-server")[0]
    port_names = {p["name"] for p in dep["spec"]["template"]["spec"]["containers"][0]["ports"]}
    assert "onscreens" in port_names, "prod re-exposes the in-pod onscreens on :8081"
    svc_ports = {p["name"] for p in _by(objs, "Service", "vlc-server")[0]["spec"]["ports"]}
    assert "onscreens" in svc_ports
    cm = _by(objs, "ConfigMap", "vlc-server-config")[0]["data"]
    assert cm["NATS_URL"].startswith("nats://")
    # stage does NOT carry the in-pod onscreens port
    stage = _by(_synth("stage-1"), "Deployment", "vlc-server")[0]
    snames = {p["name"] for p in stage["spec"]["template"]["spec"]["containers"][0]["ports"]}
    assert "onscreens" not in snames


def test_config_blocks_per_env():
    # local + dev carry the stub block; stage + prod don't.
    assert "DATABASE_USER" in _by(_synth("local"), "ConfigMap", "vlc-server-config")[0]["data"]
    assert "DATABASE_USER" in _by(_synth("development"), "ConfigMap", "vlc-server-config")[0]["data"]
    assert "DATABASE_USER" not in _by(_synth("stage-1"), "ConfigMap", "vlc-server-config")[0]["data"]
    prod_cm = _by(_synth("prod-1"), "ConfigMap", "vlc-server-config")[0]["data"]
    assert prod_cm["ENV"] == "production"
    assert prod_cm["OTEL_SDK_DISABLED"] == "false"


def test_ingress_tls_on_minipc_only():
    stage_ing = _by(_synth("stage-1"), "Ingress", "vlc-server")[0]
    assert stage_ing["spec"]["tls"][0]["secretName"] == "vlc-tls"
    assert stage_ing["metadata"]["annotations"]["cert-manager.io/issuer"] == "letsencrypt-route53"
    dev_ing = _by(_synth("development"), "Ingress", "vlc-server")[0]
    assert "tls" not in dev_ing["spec"] or not dev_ing["spec"]["tls"]
    assert not _by(_synth("local"), "Ingress", "vlc-server")
