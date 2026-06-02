"""ObsInstance factory tests: per-platform naming, streaming toggle, env knobs,
and the contract anti-drift bridge."""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import AppsChart
from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.obs import ObsInstance
from adanalife_k8s.contract import load_contract


def _synth(env_name):
    app = K8sTesting.app()
    chart = AppsChart(app, f"{env_name}-apps", env=load_env(env_name))
    return K8sTesting.synth(chart)


def _synth_obs(platform, env_name, **kwargs):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    ObsInstance(chart, platform, env=load_env(env_name), **kwargs)
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def test_youtube_factory_emits_clean_instance():
    # YouTube is deferred from the env matrix (no env emits it yet — see config.py),
    # but the ObsInstance factory must still produce clean obs-youtube objects so
    # re-enabling is a one-line config change. Test the factory directly.
    objs = _synth_obs("youtube", "stage-1", extra_config={"STREAM_PLATFORM": "youtube"})
    # Clean first-class names — NOT the kustomize obs-twitch-youtube double-suffix.
    assert _by(objs, "Deployment", "obs-youtube"), "obs-youtube deployment missing"
    assert not _by(objs, "Deployment", "obs-twitch-youtube"), "double-suffix regression"
    # Selectors are instance-scoped (the label-collision the kustomize patches fixed can't happen).
    yt = _by(objs, "Deployment", "obs-youtube")[0]
    assert yt["spec"]["selector"]["matchLabels"]["app"] == "obs-youtube"
    assert yt["spec"]["template"]["metadata"]["labels"]["app"] == "obs-youtube"
    cm = _by(objs, "ConfigMap", "obs-youtube-config")[0]
    assert cm["data"]["STREAM_PLATFORM"] == "youtube"
    # idle: no stream-key ExternalSecret (streaming off)
    assert not _by(objs, "ExternalSecret", "obs-youtube-stream-key")


def test_stage_emits_twitch_only_youtube_deferred():
    objs = _synth("stage-1")
    assert _by(objs, "Deployment", "obs-twitch"), "obs-twitch deployment missing"
    assert not _by(objs, "Deployment", "obs-youtube"), (
        "youtube is deferred from the env matrix — stage should emit twitch only"
    )


def test_prod_twitch_streams_via_eso_and_has_no_youtube():
    objs = _synth("prod-1")
    es = _by(objs, "ExternalSecret", "obs-stream-key")
    assert es, "prod twitch should create the stream-key ExternalSecret"
    assert es[0]["spec"]["data"][0]["remoteRef"]["key"] == "k8s/obs/twitch-stream-key"
    assert (
        _by(objs, "ConfigMap", "obs-twitch-config")[0]["data"]["OBS_QUALITY_PRESET"]
        == "high"
    )
    assert not _by(objs, "Deployment", "obs-youtube"), "youtube is stage-only for now"


def test_gpu_and_encoder_track_env():
    prod = _by(_synth("prod-1"), "Deployment", "obs-twitch")[0]
    reqs = prod["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"]
    assert reqs.get("gpu.intel.com/i915") == "1"
    local = _by(_synth("local"), "Deployment", "obs-twitch")[0]
    lreqs = local["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"]
    assert "gpu.intel.com/i915" not in lreqs
    assert (
        _by(_synth("local"), "ConfigMap", "obs-twitch-config")[0]["data"][
            "OBS_STREAM_ENCODER"
        ]
        == "obs_x264"
    )


def test_contract_drives_names_ports_and_urls():
    c = load_contract()
    objs = _synth("stage-1")
    svc = _by(objs, "Service", "obs-twitch")[0]
    assert svc["metadata"]["name"] == c.svc("obs_twitch")
    ports = {p["name"]: p["port"] for p in svc["spec"]["ports"]}
    assert ports["websocket"] == c.port("obs_websocket")
    assert ports["obs-server"] == c.port("obs_server")
    # OBS-config URLs are composed from contract names+ports (can't drift from the Services).
    cm = _by(objs, "ConfigMap", "obs-twitch-config")[0]["data"]
    assert cm["ONSCREENS_URL_BASE"] == c.onscreens_url_base
    assert cm["VLC_URL_BASE"] == c.vlc_url_base
    assert cm["DASHCAM_RTSP_URL"] == c.dashcam_rtsp_url


def test_local_obs_has_no_ingress():
    # OBS is VNC-port-forward-only on local; other apps (tripbot) may carry one.
    objs = _synth("local")
    obs_ingresses = [
        o
        for o in objs
        if o["kind"] == "Ingress" and o["metadata"]["name"].startswith("obs-")
    ]
    assert not obs_ingresses
