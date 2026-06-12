"""ObsInstance factory tests: per-platform naming, streaming toggle, env knobs,
and the contract anti-drift bridge."""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.obs import ObsInstance
from adanalife_k8s.contract import load_contract


def _synth(env_name):
    # the env's primary-platform OBS instance, wired exactly as emit_app_charts does.
    env = load_env(env_name)
    platform = env.platforms[0]
    streaming = platform == "twitch" and env.name == "prod-1"
    return _synth_obs(
        platform,
        env_name,
        streaming=streaming,
        stream_key_sm=f"k8s/obs/{platform}-stream-key" if streaming else None,
    )


def _synth_obs(platform, env_name, **kwargs):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    ObsInstance(chart, platform, env=load_env(env_name), **kwargs)
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def test_youtube_factory_emits_clean_instance():
    # The ObsInstance factory must produce clean obs-youtube objects (stage
    # emits them via env.platforms; prod still defers). Test the factory directly.
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


def test_platform_matrix_stage_has_youtube_prod_defers():
    # stage burns the youtube stack in first — twitch is OFF there for the
    # burn-in (the 2026-06-11 stage-starves-prod incident: both stage stacks
    # alongside prod made the prod stream stutter). prod flips to youtube
    # after the dual-encode validation. The one-shot Jobs envFrom the primary
    # (platforms[0]) ConfigMap, which on stage is now tripbot-youtube-config.
    assert load_env("stage-1").platforms == ("youtube",)
    assert load_env("prod-1").platforms == ("twitch",)
    assert load_env("development").platforms == ("twitch",)
    objs = _synth("stage-1")
    assert _by(objs, "Deployment", "obs-youtube"), "obs-youtube deployment missing"
    assert not _by(objs, "Deployment", "obs-twitch"), (
        "stage twitch is off for the burn-in"
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
    objs = _synth("stage-1")  # stage's primary platform is youtube (burn-in)
    svc = _by(objs, "Service", "obs-youtube")[0]
    assert svc["metadata"]["name"] == c.svc("obs_youtube")
    ports = {p["name"]: p["port"] for p in svc["spec"]["ports"]}
    assert ports["websocket"] == c.port("obs_websocket")
    assert ports["obs-server"] == c.port("obs_server")
    # OBS-config URLs are composed from contract names+ports (can't drift from the Services).
    cm = _by(objs, "ConfigMap", "obs-youtube-config")[0]["data"]
    assert cm["ONSCREENS_URL_BASE"] == c.onscreens_url_base("youtube")
    assert cm["VLC_URL_BASE"] == c.vlc_url_base("youtube")
    assert cm["DASHCAM_RTSP_URL"] == c.dashcam_rtsp_url("youtube")
    # the youtube obs points at the youtube vlc/onscreens
    assert cm["VLC_URL_BASE"] == "http://vlc-youtube:8080"
    assert cm["ONSCREENS_URL_BASE"] == "http://onscreens-youtube:8080"


def test_local_obs_has_no_ingress():
    # OBS is VNC-port-forward-only on local; other apps (tripbot) may carry one.
    objs = _synth("local")
    obs_ingresses = [
        o
        for o in objs
        if o["kind"] == "Ingress" and o["metadata"]["name"].startswith("obs-")
    ]
    assert not obs_ingresses
