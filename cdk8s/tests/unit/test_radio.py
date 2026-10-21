"""Radio station tests — the station plays off the node-local music claim the
album bed uses (never the NFS one), and every station mount the Liquidsoap
script declares is pushed to the Icecast container in the same pod."""

import pytest
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import SupportingChart
from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.music import LOCAL_CLAIM
from adanalife_k8s.constructs.radio import NAME, PORT, STATIONS, _script


def _synth(env_name):
    app = K8sTesting.app()
    return K8sTesting.synth(SupportingChart(app, "t", env=load_env(env_name)))


def _deployment(objs):
    hits = [
        o for o in objs if o["kind"] == "Deployment" and o["metadata"]["name"] == NAME
    ]
    assert len(hits) == 1
    return hits[0]


@pytest.mark.parametrize("env_name", ["stage-1", "prod-1"])
def test_plays_off_the_local_music_claim(env_name):
    spec = _deployment(_synth(env_name))["spec"]["template"]["spec"]
    claims = [
        v["persistentVolumeClaim"]
        for v in spec["volumes"]
        if "persistentVolumeClaim" in v
    ]
    assert claims == [{"claimName": LOCAL_CLAIM, "readOnly": True}]


def test_not_rendered_without_the_music_volume():
    assert not [o for o in _synth("development") if o["metadata"]["name"] == NAME]


def test_script_pushes_every_station_to_the_pod_local_icecast():
    script = _script()
    assert script.count("output.icecast(") == len(STATIONS)
    assert f'host = "127.0.0.1",\n  port = {PORT},' in script
    for mount, folder, _ in STATIONS:
        assert f'mount = "{mount}"' in script
        assert f'"/music/{folder}"' in script


def test_an_empty_station_drops_its_mount_instead_of_airing_silence():
    # mksafe would serve silence, which tripbot's reachability probe reads as a
    # healthy stream, so the watchdog would swap back to it every cooldown.
    script = _script()
    assert "mksafe" not in script
    assert script.count("fallible = true") == len(STATIONS)


@pytest.mark.parametrize("env_name", ["stage-1", "prod-1"])
def test_every_container_runs_as_a_numeric_uid(env_name):
    # Both images declare a named USER, which runAsNonRoot can't verify: the
    # kubelet refuses to start a container without a numeric uid to check.
    spec = _deployment(_synth(env_name))["spec"]["template"]["spec"]
    pod_uid = spec["securityContext"].get("runAsUser")
    for c in spec["initContainers"] + spec["containers"]:
        uid = c.get("securityContext", {}).get("runAsUser", pod_uid)
        assert isinstance(uid, int) and uid > 0, c["name"]


def test_icecast_serves_utf8_titles():
    # Without a mount charset Icecast transcodes MP3 titles to ISO8859-1, which
    # tripbot's now-playing can't decode ("Blue Öyster Cult" loses its Ö).
    spec = _deployment(_synth("prod-1"))["spec"]["template"]["spec"]
    (icecast,) = [c for c in spec["containers"] if c["name"] == "icecast"]
    assert (
        '<mount type="default"><charset>UTF-8</charset></mount>'
        in icecast["command"][-1]
    )
