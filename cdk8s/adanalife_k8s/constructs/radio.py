"""The fleet's own internet-radio station — an Icecast server fed by Liquidsoap,
shuffling album directories of the music library, so tripbot's radio bed has
stations of ours to play alongside the third-party ones in its station list.

One pod, two containers: Liquidsoap encodes the playlist to MP3 and pushes it to
Icecast over the pod's loopback; Icecast serves it with in-band ICY metadata
(StreamTitle = "artist - title"), which is what the bed's now-playing reads.

Plays off `obs-music-local`, the node-local mirror the album bed reads, never the
NFS share (decisions/prod-stream-path-no-nas-dependency): a station is staged by
putting a directory on the share and running `task k8s:<env>:music-localize`.
Only tracks inside an album directory count, as for the album bed: the loose
files at the library's root never play. Each station rescans the library every
minute, so an album that lands in a directory it matches joins it unprompted.
A station with no tracks takes its mount down rather than airing silence:
Icecast then answers 404, which tripbot's audio watchdog treats as an outage
and covers with a local bed, where silence would pass its probe and flap.

The source/admin password is minted per pod by an initContainer onto a
memory-backed emptyDir both containers read, so there is no credential to store
anywhere and the Service's port is useless to anyone else as a source.

Listeners address it as
http://radio.<ns>.svc.cluster.local:8000/<mount> — the URL that goes in
tripbot's station list (SSM /k8s/tripbot/radio-stations). ClusterIP only.

Each station also airs a request queue ahead of its shuffle, driven over a JSON
control API on port 8001 (`control`): `GET /stations/<mount>/queue` and
`/tracks`, `POST .../skip`, `.../back`, `.../push` (`{"file": ...}`, a file of
the station's own scan) and `.../drop/<rid>`. The console uses it to show and
steer what each station plays.
"""

from __future__ import annotations

import re

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.constructs.dashcam import MINIPC_NODE
from adanalife_k8s.constructs.music import AUDIO_EXTS, LOCAL_CLAIM
from adanalife_k8s.naming import (
    CONFIG_HASH_ANNOTATION,
    config_hash,
    meta_labels,
    selector,
)

# Upstream registries rather than ghcr mirrors: the mirror rule
# (ghcr-base-image-mirrors) exists for CI pulls, and these are cluster pulls.
# shortcut: liquidsoap comes off Docker Hub; mirror it via a mirror-images.yml
# pair if a pull ever hits the Hub rate limit.
ICECAST_IMAGE = "ghcr.io/libretime/icecast:2.5.0-alpine"
LIQUIDSOAP_IMAGE = "docker.io/savonet/liquidsoap:v2.4.6"

NAME = "radio"
PORT = 8000
CONTROL_PORT = 8001
_MUSIC_DIR = "/music"
_RUN_DIR = "/run/radio"
_PASSWORD_FILE = f"{_RUN_DIR}/password"

# One mount per station: (mount, album directories, display name). A directory
# is a name under the music share's root, where `*` matches within the name.
# The station shuffles every track under all of them as one list, so each track
# is equally likely whichever album it is on.
STATIONS = (
    (
        "adanalife",
        ("streambeats-*", "fifty-horizons", "wyoming-miles"),
        "A Dana Life",
    ),
    ("halloween", ("halloween",), "Halloween"),
    ("keep-it-spooky", ("keep-it-spooky",), "Keep it Spooky"),
)
_RESCAN_SECONDS = 60

# The images' own users (icecast owns /etc/icecast.xml, which its entrypoint
# edits in place); runAsNonRoot needs them numeric.
_ICECAST_UID = 1000
_LIQUIDSOAP_UID = 100


# Icecast's MP3 mounts default to ISO8859-1 metadata, so it transcodes the UTF-8
# titles Liquidsoap sends and "Blue Öyster Cult" reaches tripbot as Latin-1
# bytes that don't decode. A default <mount> charset keeps them UTF-8. The
# config is rewritten through its contents because icecast owns the file but
# not /etc, where `sed -i` would need to create its temp file. The image's
# entrypoint then writes the password env vars into it before exec'ing icecast.
# The image's config also caps sources at 2, and each station is one source, so
# the cap is raised to the station count or the mounts past it are refused.
_DEFAULT_MOUNT = '<mount type="default"><charset>UTF-8</charset></mount>'
_ICECAST_START = (
    'c="$(sed '
    f"-e 's|</icecast>|{_DEFAULT_MOUNT}</icecast>|' "
    f"-e 's|<sources>[0-9]*</sources>|<sources>{len(STATIONS)}</sources>|' "
    '/etc/icecast.xml)" '
    "&& printf '%s\\n' \"$c\" > /etc/icecast.xml && "
    f'p="$(cat {_PASSWORD_FILE})"; '
    'export ICECAST_SOURCE_PASSWORD="$p" '
    'ICECAST_ADMIN_PASSWORD="$p" '
    'ICECAST_RELAY_PASSWORD="$p"; '
    "exec docker-entrypoint icecast -c /etc/icecast.xml"
)


def _pattern(folders: tuple[str, ...]) -> str:
    """A Liquidsoap regexp matching the files under any of `folders`."""
    for f in folders:
        # Names go into the regexp verbatim, so they are held to a safe alphabet.
        if not re.fullmatch(r"[a-z0-9*-]+", f):
            raise ValueError(f"radio directory {f!r}: use [a-z0-9-] and *")
    names = "|".join(f.replace("*", r"[^\/]*") for f in folders)
    # The slash after the album keeps loose root files out; the extension keeps
    # out cover art and Synology's `@eaDir/<track>@SynoEAStream` sidecars.
    root = _MUSIC_DIR.replace("/", r"\/")
    exts = "|".join(AUDIO_EXTS)
    return rf"r/^{root}\/({names})\/.*\.({exts})$/i"


# The control API: Liquidsoap's own HTTP server answers JSON about each
# station's queue and takes skip/back/push/drop. It is unauthenticated, which is
# why the Service is ClusterIP only and a push names a file of the station's
# own scan, never an arbitrary URI.
_CONTROL = """
def entry(~requested = false, ~rid = null, filename, m) =
  {
    file = filename,
    artist = m["artist"],
    title = m["title"],
    requested = requested,
    rid = rid
  }
end

def played_track(p) =
  let (m, requested) = p
  entry(requested = requested, m["filename"], m)
end

def pending_track(r) =
  entry(requested = true, rid = request.id(r), request.uri(r), request.metadata(r))
end

# A source's loaded request that is not the one on air: the fallback leaves it
# waiting while another source plays, and it airs when that source yields.
def waiting(s, on_air) =
  r = s.current()
  if
    null.defined(r) and string(request.id(null.get(r))) != on_air
  then
    [null.get(r)]
  else
    []
  end
end

def requests(st, on_air) =
  [
    ...waiting(st.replay, on_air),
    ...st.replay.queue(),
    ...waiting(st.pending, on_air),
    ...st.pending.queue()
  ]
end

def queue_json(st) =
  on_air =
    list.case(
      st.played(),
      "",
      fun (p, _) ->
        begin
          let (m, _) = p
          m["rid"]
        end
    )
  pending =
    list.map(pending_track, requests(st, on_air))
  upcoming = [
    ...list.map(
      request.uri,
      [...waiting(st.shuffle, on_air), ...st.shuffle.queue()]
    ),
    ...st.shuffle.remaining_files()
  ]
  shuffle = list.map(fun (f) -> entry(f, []), upcoming)
  played = list.map(played_track, st.played())
  {
    now = list.case(played, null, fun (t, _) -> t),
    next = list.prefix(50, [...pending, ...shuffle]),
    history = list.tl(played)
  }
end

# Writes the body by hand rather than through `res.json`, which would pin `res`
# to this one JSON shape for the handler sharing it.
def fail(res, code, msg) =
  res.status_code(code)
  res.content_type("application/json; charset=utf-8")
  res.data(json.stringify(compact = true, {error = msg}))
end

def route(method, suffix, handler) =
  harbor.http.register(
    port = control_port,
    method = method,
    "/stations/:mount" ^ suffix,
    fun (req, res) ->
      begin
        st = list.assoc.nullable(req.query["mount"], stations())
        if
          null.defined(st)
        then
          handler(null.get(st), req, res)
        else
          fail(res, 404, "no such station")
        end
      end
  )
end

route("GET", "/queue", fun (st, _, res) -> res.json(queue_json(st)))

route(
  "GET",
  "/tracks",
  fun (st, _, res) ->
    res.json(
      list.map(
        fun (f) -> entry(f, []),
        list.sort(fun (a, b) -> if a < b then -1 elsif a > b then 1 else 0 end, st.known())
      )
    )
)

route(
  "POST",
  "/skip",
  fun (st, _, res) ->
    begin
      st.aired.skip()
      res.status_code(204)
    end
)

route(
  "POST",
  "/back",
  fun (st, _, res) ->
    begin
      played = st.played()
      if
        list.length(played) < 2
      then
        fail(res, 409, "nothing to go back to")
      else
        let (previous, _) = list.nth(played, 1)
        st.replay.push(request.create(previous["filename"]))
        st.aired.skip()
        res.status_code(204)
      end
    end
)

route(
  "POST",
  "/push",
  fun (st, req, res) ->
    begin
      wanted =
        try
          let json.parse (body : {file: string}) = req.body()
          body.file
        catch _ do
          ""
        end
      if
        list.mem(wanted, st.known())
      then
        r = request.create(wanted)
        st.pending.push(r)
        res.json({rid = request.id(r)})
      else
        fail(res, 404, "not a track of this station")
      end
    end
)

route(
  "POST",
  "/drop/:rid",
  fun (st, req, res) ->
    begin
      rid = int_of_string(default = -1, req.query["rid"])
      if
        list.exists(fun (r) -> request.id(r) == rid, requests(st, ""))
      then
        st.replay.remove_request_id(rid)
        st.pending.remove_request_id(rid)
        # Dropping the request a queue has loaded leaves it empty-handed until
        # it fetches again, and a track ending in between would skip the queue.
        st.replay.fetch()
        st.pending.fetch()
        res.status_code(204)
      else
        fail(res, 404, "no such request")
      end
    end
)
"""


def _script() -> str:
    outputs = "\n".join(
        f"""output.icecast(
  %mp3(bitrate = 128),
  host = "127.0.0.1",
  port = {PORT},
  password = password,
  mount = "{mount}",
  name = "{title}",
  fallible = true,
  station("{mount}", {_pattern(folders)})
)"""
        for mount, folders, title in STATIONS
    )
    return f"""settings.log.stdout := true
settings.log.file := false
password = string.trim(file.contents("{_PASSWORD_FILE}"))
control_port = {CONTROL_PORT}
stations = ref([])
# Measures each track's integrated loudness as it is prepared, off air, into
# the `lufs_track_gain` that normalize_track_gain applies.
enable_lufs_track_gain_metadata()

# A station airs its request queue ahead of a shuffled playlist of every
# library track whose path matches `pattern`, reloaded when a rescan finds the
# set changed. With no tracks and no requests it is never ready, so its
# fallible output keeps the mount down.
def station(mount, pattern) =
  shuffle = playlist.list(mode = "randomize", [])
  known = ref([])
  def rescan() =
    tracks = list.filter(fun (f) -> pattern.test(f), playlist.files("{_MUSIC_DIR}"))
    if tracks != known() then
      known := tracks
      shuffle.reload(empty_queue = false, tracks)
    end
  end
  thread.run(every = {_RESCAN_SECONDS}., rescan)
  pending = request.queue(id = "#{{mount}}-queue", interactive = false)
  # `back` replays through a queue of its own, ahead of the pending one:
  # request.queue's set_queue destroys the request it has already loaded, so
  # pushing to the front of `pending` would lose that request.
  replay = request.queue(id = "#{{mount}}-replay", interactive = false)
  aired = fallback([replay, pending, shuffle])
  # Newest first, each with whether the request queue supplied it: the head is
  # what is on air, the rest is history.
  played = ref([])
  def from_queue(m) =
    list.exists(
      fun (q) ->
        begin
          r = q.current()
          null.defined(r) and string(request.id(null.get(r))) == m["rid"]
        end,
      [replay, pending]
    )
  end
  aired.on_track(
    synchronous = true,
    fun (m) -> played := list.prefix(11, [(m, from_queue(m)), ...played()])
  )
  stations := [
    ...stations(),
    (
      mount,
      {{
        shuffle = shuffle,
        known = known,
        pending = pending,
        replay = replay,
        aired = aired,
        played = played
      }}
    )
  ]
  # A track's silent tail or intro airs at most 5s of silence: the ~20s some
  # tracks carry reads to tripbot's audio watchdog as an outage, and it swaps
  # the stream onto its fallback bed.
  quiet_gaps_cut = blank.eat(max_blank = 5., threshold = -50., aired)
  # Every track lands at the same loudness (settings.lufs.track_gain_target,
  # -16 LUFS), so albums mastered years apart sit level; the limiter catches
  # the peaks a quiet track's gain-up pushes toward clipping.
  limit(normalize_track_gain(quiet_gaps_cut))
end
{_CONTROL}
{outputs}
"""


class Radio(Construct):
    def __init__(self, scope: Construct, id: str = "radio", *, env: EnvConfig):
        super().__init__(scope, id)
        ns = env.namespace or None
        labels = meta_labels(NAME)
        sel = selector(NAME)
        config = {"radio.liq": _script()}
        q = k8s.Quantity.from_string

        k8s.KubeConfigMap(
            self,
            "config",
            metadata=k8s.ObjectMeta(name=f"{NAME}-config", namespace=ns, labels=labels),
            data=config,
        )

        run = k8s.VolumeMount(name="run", mount_path=_RUN_DIR)
        locked_down = k8s.SecurityContext(
            allow_privilege_escalation=False,
            capabilities=k8s.Capabilities(drop=["ALL"]),
        )

        k8s.KubeDeployment(
            self,
            "deployment",
            metadata=k8s.ObjectMeta(name=NAME, namespace=ns, labels=labels),
            spec=k8s.DeploymentSpec(
                replicas=1,
                strategy=k8s.DeploymentStrategy(type="Recreate"),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    metadata=k8s.ObjectMeta(
                        labels=sel,
                        annotations={CONFIG_HASH_ANNOTATION: config_hash(config)},
                    ),
                    spec=k8s.PodSpec(
                        # The music claim is local-path, so it only exists here.
                        node_selector={"kubernetes.io/hostname": MINIPC_NODE},
                        security_context=k8s.PodSecurityContext(
                            run_as_non_root=True,
                            run_as_user=_ICECAST_UID,
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault"),
                        ),
                        init_containers=[
                            k8s.Container(
                                name="password",
                                image=ICECAST_IMAGE,
                                command=[
                                    "sh",
                                    "-c",
                                    "head -c 24 /dev/urandom | base64 | tr -d '/+=' "
                                    f"> {_PASSWORD_FILE} && chmod 444 {_PASSWORD_FILE}",
                                ],
                                security_context=locked_down,
                                resources=k8s.ResourceRequirements(
                                    requests={"cpu": q("10m"), "memory": q("16Mi")},
                                    limits={"memory": q("32Mi")},
                                ),
                                volume_mounts=[run],
                            )
                        ],
                        containers=[
                            k8s.Container(
                                name="icecast",
                                image=ICECAST_IMAGE,
                                command=["sh", "-c", _ICECAST_START],
                                ports=[
                                    k8s.ContainerPort(name="http", container_port=PORT)
                                ],
                                readiness_probe=k8s.Probe(
                                    tcp_socket=k8s.TcpSocketAction(
                                        port=k8s.IntOrString.from_string("http")
                                    ),
                                    period_seconds=10,
                                ),
                                security_context=locked_down,
                                resources=k8s.ResourceRequirements(
                                    requests={"cpu": q("20m"), "memory": q("32Mi")},
                                    limits={"memory": q("128Mi")},
                                ),
                                volume_mounts=[run],
                            ),
                            k8s.Container(
                                name="liquidsoap",
                                image=LIQUIDSOAP_IMAGE,
                                args=["/etc/radio/radio.liq"],
                                ports=[
                                    k8s.ContainerPort(
                                        name="control", container_port=CONTROL_PORT
                                    )
                                ],
                                # The console drives each station through this port, so
                                # a pod without it isn't ready, however well Icecast is.
                                readiness_probe=k8s.Probe(
                                    tcp_socket=k8s.TcpSocketAction(
                                        port=k8s.IntOrString.from_string("control")
                                    ),
                                    period_seconds=10,
                                ),
                                security_context=k8s.SecurityContext(
                                    allow_privilege_escalation=False,
                                    capabilities=k8s.Capabilities(drop=["ALL"]),
                                    run_as_user=_LIQUIDSOAP_UID,
                                ),
                                # One 128k MP3 encode per station.
                                resources=k8s.ResourceRequirements(
                                    requests={"cpu": q("100m"), "memory": q("128Mi")},
                                    limits={"memory": q("512Mi")},
                                ),
                                volume_mounts=[
                                    run,
                                    k8s.VolumeMount(
                                        name="config",
                                        mount_path="/etc/radio",
                                        read_only=True,
                                    ),
                                    k8s.VolumeMount(
                                        name="music",
                                        mount_path=_MUSIC_DIR,
                                        read_only=True,
                                    ),
                                ],
                            ),
                        ],
                        volumes=[
                            k8s.Volume(
                                name="run",
                                empty_dir=k8s.EmptyDirVolumeSource(medium="Memory"),
                            ),
                            k8s.Volume(
                                name="config",
                                config_map=k8s.ConfigMapVolumeSource(
                                    name=f"{NAME}-config"
                                ),
                            ),
                            k8s.Volume(
                                name="music",
                                persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                                    claim_name=LOCAL_CLAIM, read_only=True
                                ),
                            ),
                        ],
                    ),
                ),
            ),
        )

        k8s.KubeService(
            self,
            "service",
            metadata=k8s.ObjectMeta(name=NAME, namespace=ns, labels=labels),
            spec=k8s.ServiceSpec(
                selector=sel,
                ports=[
                    k8s.ServicePort(
                        name="http",
                        port=PORT,
                        target_port=k8s.IntOrString.from_string("http"),
                    ),
                    k8s.ServicePort(
                        name="control",
                        port=CONTROL_PORT,
                        target_port=k8s.IntOrString.from_string("control"),
                    ),
                ],
            ),
        )
