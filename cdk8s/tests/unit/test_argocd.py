"""The Argo CD config is parameterized by env-set so one authoring path emits both
the minipc instance (prod-1 + stage-1, tailscale UI) and a SEPARATE k3d dev-cluster
instance (development only, no UI). Each Argo runs in its own cluster and targets
in-cluster — no cross-cluster wiring. These pin that the dev variant is scoped to
development and the data unit never prunes on either.
"""

import pytest
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArgoCDChart

_DEV = dict(
    envs=("development",),
    autosync_envs=("development",),
    autosync_holdouts=(),
    selfheal=False,  # dev autosyncs but doesn't revert hand-edits (scratch env)
    notifications_secret=False,
    tailscale_ui=False,
    lan_host="argocd.dev.whereisdana.today",
    lan_tls=False,
    ups_monitor=False,  # dev can't reach the Synology NUT server
    arc=False,  # no rpi5 on the k3d dev cluster — self-hosted runners are minipc-only
)


def _synth(**kwargs):
    app = K8sTesting.app()
    chart = ArgoCDChart(app, "argocd", **kwargs)
    return K8sTesting.synth(chart)


def _appset(objs, name):
    return next(
        o
        for o in objs
        if o["kind"] == "ApplicationSet" and o["metadata"]["name"] == name
    )


def _project(objs, name):
    return next(
        o for o in objs if o["kind"] == "AppProject" and o["metadata"]["name"] == name
    )


def _ignores_replicas(appset):
    """True when the appset's Application template ignores every Deployment's
    .spec.replicas — the runtime-owned-replicas contract (a console/hand scale
    sticks; selfHeal never reconciles the count)."""
    diffs = appset["spec"]["template"]["spec"]["ignoreDifferences"]
    return any(
        d.get("kind") == "Deployment"
        and ".spec.replicas" in d.get("jqPathExpressions", [])
        for d in diffs
    )


def test_minipc_default_has_both_uis_and_both_envs():
    objs = _synth()
    classes = {
        o["spec"].get("ingressClassName") for o in objs if o["kind"] == "Ingress"
    }
    assert classes == {"tailscale", "traefik"}  # tailnet UI + LAN UI
    # tripbot-apps self-discovers deploy units from the tripbot repo's index
    # (git files generator); the per-env globs scope which envs it delivers.
    globs = _appset(objs, "tripbot-apps")["spec"]["generators"][0]["git"]["files"]
    envs = {f["path"].split("/")[-1].removesuffix("-*.json") for f in globs}
    assert envs == {"prod-1", "stage-1"}


def test_dev_is_development_only_with_traefik_ui():
    objs = _synth(**_DEV)
    ingresses = [o for o in objs if o["kind"] == "Ingress"]
    # exactly one UI Ingress on dev — traefik, no tailscale, no TLS (reached at :9080)
    assert len(ingresses) == 1
    ing = ingresses[0]
    assert ing["spec"]["ingressClassName"] == "traefik"
    assert "tls" not in ing["spec"]
    assert (
        ing["metadata"]["annotations"]["external-dns.alpha.kubernetes.io/hostname"]
        == "argocd.dev.whereisdana.today"
    )
    # dev runs the per-repo tripbot + infra projects, plus obs (the public obs
    # repo delivers dev OBS now) — but no console/video-pipeline (private repos).
    assert {o["metadata"]["name"] for o in objs if o["kind"] == "AppProject"} == {
        "tripbot",
        "infra",
        "obs",
    }
    for name in ("tripbot", "infra", "obs"):
        assert {
            d["namespace"] for d in _project(objs, name)["spec"]["destinations"]
        } == {"development"}
    # development apps autosync (it's throwaway)...
    patch = _appset(objs, "tripbot-apps")["spec"]["templatePatch"]
    assert "development" in patch
    # ...but selfHeal is OFF so a hand `kubectl edit` sticks (autosync + prune stay on)
    assert "prune: true" in patch
    assert "selfHeal: false" in patch


def test_per_repo_projects_scope_to_one_repo_each():
    # One AppProject per source repo: each project's sourceRepos is locked to its
    # single repo, and every ApplicationSet is assigned to the project for the repo
    # it sources, so a misconfigured Application can't pull from another repo or
    # sync into another tenant's namespace.
    objs = _synth()
    want_repos = {
        "tripbot": ["https://github.com/adanalife/tripbot.git"],
        "infra": ["git@github.com:adanalife/infra.git"],
        "tripbot-console": ["git@github.com:adanalife/tripbot-console.git"],
        "video-pipeline": ["git@github.com:adanalife/video-pipeline.git"],
        "platform-gateway": ["git@github.com:adanalife/platform-gateway.git"],
        "obs": ["https://github.com/adanalife/obs.git"],
        "playout": ["https://github.com/adanalife/playout.git"],
    }
    assert {o["metadata"]["name"] for o in objs if o["kind"] == "AppProject"} == set(
        want_repos
    )
    for name, repos in want_repos.items():
        assert _project(objs, name)["spec"]["sourceRepos"] == repos
    # each ApplicationSet rides the project matching the repo it sources
    for appset, project in (
        ("tripbot-apps", "tripbot"),
        ("tripbot-identity", "tripbot"),
        ("tripbot-supporting", "infra"),
        ("tripbot-data", "infra"),
        ("tripbot-console", "tripbot-console"),
        ("video-pipeline", "video-pipeline"),
        ("platform-gateway", "platform-gateway"),
        ("obs", "obs"),
        ("playout", "playout"),
        ("mediamtx", "infra"),
    ):
        assert _appset(objs, appset)["spec"]["template"]["spec"]["project"] == project
    # cluster-resource allowlists are scoped to what each repo's dist actually
    # creates: infra owns the platform cluster-scoped kinds, the console none.
    kinds = lambda n: {  # noqa: E731
        c["kind"] for c in _project(objs, n)["spec"]["clusterResourceWhitelist"]
    }
    # minipc default includes the UPS monitor, whose CreateNamespace=true sync
    # needs Namespace permitted here (see test_ups_monitor for the dev exclusion).
    assert kinds("infra") == {
        "PersistentVolume",
        "StorageClass",
        "PriorityClass",
        "Namespace",
    }
    assert kinds("tripbot") == {"PriorityClass"}
    assert kinds("video-pipeline") == {"PriorityClass"}
    assert kinds("tripbot-console") == set()
    assert kinds("platform-gateway") == set()
    assert kinds("playout") == set()
    # destinations are scoped to the namespaces each project's apps target. The
    # console reaches into the isolated data namespace too (read-only RBAC for
    # the live status views), so its project must permit both — tripbot apps and
    # video-pipeline only touch the app namespace.
    dests = lambda n: {  # noqa: E731
        d["namespace"] for d in _project(objs, n)["spec"]["destinations"]
    }
    assert dests("tripbot") == {"prod-1", "stage-1"}
    assert dests("tripbot-console") == {
        "prod-1",
        "stage-1",
        "prod-1-data",
        "stage-1-data",
    }
    assert dests("video-pipeline") == {"prod-1", "stage-1"}
    assert dests("platform-gateway") == {"prod-1", "stage-1"}
    assert dests("playout") == {"prod-1", "stage-1"}


def test_minipc_apps_autosync_except_prod_obs():
    objs = _synth()
    patch = _appset(objs, "tripbot-apps")["spec"]["templatePatch"]
    # both minipc envs are automated in tripbot-apps...
    assert '(eq .env "stage-1")' in patch
    assert '(eq .env "prod-1")' in patch
    # ...and tripbot-apps carries no obs unit — OBS is delivered by the
    # obs repo's own appset (OBS_REVISIONS), so there's no obs carve-out here.
    assert "obs" not in patch
    # selfHeal is uniformly ON (both minipc envs match git for image/config/
    # existence drift) — no per-env or per-app selfHeal carve-out. Scaling no
    # longer fights selfHeal because the replica count is runtime-owned: Argo
    # ignores .spec.replicas on the app Deployments, so a console scale sticks.
    assert "selfHeal: true" in patch
    assert "selfHeal: false" not in patch
    assert _ignores_replicas(_appset(objs, "tripbot-apps"))
    # the live-encoder holdout moved with OBS to the obs appset: each prod-1 obs
    # platform is a deliberate manual sync (a sync restarts the live stream),
    # the rest autosync.
    obs = _appset(objs, "obs")
    obs_patch = obs["spec"]["templatePatch"]
    assert '(and (eq .env "prod-1") (eq .app "obs-twitch"))' in obs_patch
    assert '(and (eq .env "prod-1") (eq .app "obs-youtube"))' in obs_patch
    # selfHeal uniformly ON here too; obs replicas are runtime-owned (a console
    # scale-up of a parked platform sticks).
    assert "selfHeal: true" in obs_patch
    assert "selfHeal: false" not in obs_patch
    assert _ignores_replicas(obs)
    # one Application per (env, platform), each reconciling its own dist file
    elements = obs["spec"]["generators"][0]["list"]["elements"]
    assert {(e["env"], e["app"]) for e in elements} == {
        ("prod-1", "obs-twitch"),
        ("prod-1", "obs-youtube"),
        ("prod-1", "obs-facebook"),
        ("stage-1", "obs-twitch"),
        ("stage-1", "obs-youtube"),
        ("stage-1", "obs-facebook"),
    }
    src = obs["spec"]["template"]["spec"]["source"]
    assert src["directory"]["include"] == "{{.env}}-{{.app}}.k8s.yaml"
    # supporting + data + identity stay manual everywhere
    for name in ("tripbot-supporting", "tripbot-data", "tripbot-identity"):
        assert "templatePatch" not in _appset(objs, name)["spec"]


def test_identity_appset_sources_tripbot_and_never_prunes():
    # The cross-repo identity unit: per-env identity Secrets + stream protection
    # sourced from the tripbot repo, Prune=false (creationPolicy:Owner ESes own
    # the materialized creds — an accidental prune would GC live credentials).
    for kwargs, want_envs in (({}, {"prod-1", "stage-1"}), (_DEV, {"development"})):
        objs = _synth(**kwargs)
        ident = _appset(objs, "tripbot-identity")
        elements = ident["spec"]["generators"][0]["list"]["elements"]
        assert {e["env"] for e in elements} == want_envs
        src = ident["spec"]["template"]["spec"]["source"]
        assert src["repoURL"] == "https://github.com/adanalife/tripbot.git"
        assert src["directory"]["include"] == "{{.env}}-tripbot-identity.k8s.yaml"
        opts = ident["spec"]["template"]["spec"]["syncPolicy"]["syncOptions"]
        assert "Prune=false" in opts
        # trunk-based repo: every env tracks main (prod is release-gated by the
        # image pin, not a branch)
        revs = {e["env"]: e["revision"] for e in elements}
        assert all(v == "main" for v in revs.values())


def test_notifications_secret_minipc_only():
    def names(objs):
        return {o["metadata"]["name"] for o in objs if o["kind"] == "ExternalSecret"}

    # minipc: infra + console + video-pipeline + platform-gateway repo creds + the
    # notifications webhook
    assert names(_synth()) == {
        "argocd-repo-infra",
        "argocd-repo-tripbot-console",
        "argocd-repo-video-pipeline",
        "argocd-repo-platform-gateway",
        "argocd-notifications",
    }
    # dev runs notifications.enabled=false, so no webhook secret there
    assert names(_synth(**_DEV)) == {"argocd-repo-infra"}


def test_video_pipeline_appset_both_envs_cross_repo():
    objs = _synth()
    vp = _appset(objs, "video-pipeline")
    revs = {
        e["env"]: e["revision"] for e in vp["spec"]["generators"][0]["list"]["elements"]
    }
    # trunk-based repo: both envs track main (stage = batch stack + parked
    # responder, prod = the !find embed responder only)
    assert revs == {"stage-1": "main", "prod-1": "main"}
    src = vp["spec"]["template"]["spec"]["source"]
    assert src["repoURL"] == "git@github.com:adanalife/video-pipeline.git"
    # exact-match include: the persistent unit, not the sibling -jobs file
    assert src["directory"]["include"] == "{{.env}}.k8s.yaml"
    assert "automated" in vp["spec"]["templatePatch"]  # both envs autosync
    # dev cluster carries no private-repo deploy key, so no video-pipeline unit
    with pytest.raises(StopIteration):
        _appset(_synth(**_DEV), "video-pipeline")


def test_platform_gateway_appset_per_platform_cross_repo():
    objs = _synth()
    pg = _appset(objs, "platform-gateway")
    elements = pg["spec"]["generators"][0]["list"]["elements"]
    # one Application per gateway instance (PLATFORM_GATEWAY_PLATFORMS — the
    # cross-repo contract with the gateway repo's env.platforms) plus the
    # per-env shared unit carrying the once-per-namespace ExternalSecrets
    apps = {(e["env"], e["app"]) for e in elements}
    assert {a for a in apps if a[0] == "prod-1"} == {
        ("prod-1", "gateway-twitch"),
        ("prod-1", "gateway-youtube"),
        ("prod-1", "gateway-facebook"),
        ("prod-1", "gateway-shared"),
    }
    assert {a[1] for a in apps if a[0] == "stage-1"} == {
        "gateway-twitch",
        "gateway-youtube",
        "gateway-tiktok",
        "gateway-facebook",
        "gateway-instagram",
        "gateway-shared",
    }
    # trunk-based repo: every element tracks main
    assert all(e["revision"] == "main" for e in elements)
    src = pg["spec"]["template"]["spec"]["source"]
    assert src["repoURL"] == "git@github.com:adanalife/platform-gateway.git"
    assert src["directory"]["include"] == "{{.env}}-{{.app}}.k8s.yaml"
    assert "automated" in pg["spec"]["templatePatch"]  # autosyncs like the others
    # an app rename / platform removal must never cascade-delete live gateways
    assert pg["spec"]["syncPolicy"] == {"preserveResourcesOnDeletion": True}
    # dev cluster carries no private-repo deploy key, so no platform-gateway unit
    with pytest.raises(StopIteration):
        _appset(_synth(**_DEV), "platform-gateway")


def test_playout_appset_cross_repo_with_prod_holdout():
    objs = _synth()
    po = _appset(objs, "playout")
    src = po["spec"]["template"]["spec"]["source"]
    assert src["repoURL"] == "https://github.com/adanalife/playout.git"
    # one Application per (env, platform), each reconciling its own dist file
    # (PLAYOUT_PLATFORMS — stage runs the facebook burn-in, youtube parked)
    assert src["directory"]["include"] == "{{.env}}-{{.app}}.k8s.yaml"
    elements = po["spec"]["generators"][0]["list"]["elements"]
    assert {(e["env"], e["app"]) for e in elements} == {
        ("prod-1", "playout-twitch"),
        ("prod-1", "playout-youtube"),
        ("prod-1", "playout-facebook"),
        ("stage-1", "playout-youtube"),
        ("stage-1", "playout-facebook"),
    }
    assert all(e["revision"] == "main" for e in elements)
    # prod playout feeds the live stream at cutover — deliberate manual sync
    patch = po["spec"]["templatePatch"]
    assert '(and (eq .env "prod-1") (eq .app "playout-twitch"))' in patch
    assert '(and (eq .env "prod-1") (eq .app "playout-youtube"))' in patch
    # selfHeal uniformly ON; playout replicas are runtime-owned so a console
    # scale-up of a parked platform sticks.
    assert "selfHeal: true" in patch
    assert "selfHeal: false" not in patch
    assert _ignores_replicas(po)
    # the public repo needs no deploy key, and the dev cluster runs no playout
    dev = _synth(**_DEV)
    with pytest.raises(StopIteration):
        _appset(dev, "playout")
    assert "playout" not in {
        o["metadata"]["name"] for o in dev if o["kind"] == "AppProject"
    }


def test_mediamtx_appset_autosyncs_both_envs():
    objs = _synth()
    mtx = _appset(objs, "mediamtx")
    src = mtx["spec"]["template"]["spec"]["source"]
    # infra-authored unit: sources the infra repo like supporting/data...
    assert src["repoURL"] == "git@github.com:adanalife/infra.git"
    # ...one Application per (env, platform), fan-out from the infra env config
    assert src["directory"]["include"] == "{{.env}}-{{.app}}.k8s.yaml"
    elements = mtx["spec"]["generators"][0]["list"]["elements"]
    assert {(e["env"], e["app"]) for e in elements} == {
        ("prod-1", "mediamtx-twitch"),
        ("prod-1", "mediamtx-youtube"),
        ("prod-1", "mediamtx-facebook"),
        ("stage-1", "mediamtx-twitch"),
        ("stage-1", "mediamtx-youtube"),
        ("stage-1", "mediamtx-facebook"),
    }
    # ...autosyncing (a merged dist change deploys itself) with selfHeal ON on
    # both envs — the relay is never parked (always replicas:1, cheap), so its
    # count stays git-owned: no ignore_replicas, unlike the parkable workloads.
    patch = mtx["spec"]["templatePatch"]
    assert "prune: true" in patch
    assert "selfHeal: true" in patch
    assert "selfHeal: false" not in patch
    assert not _ignores_replicas(mtx)
    with pytest.raises(StopIteration):
        _appset(_synth(**_DEV), "mediamtx")


def test_data_appset_never_prunes_either_variant():
    for kwargs in ({}, _DEV):
        data = _appset(_synth(**kwargs), "tripbot-data")
        opts = data["spec"]["template"]["spec"]["syncPolicy"]["syncOptions"]
        assert "Prune=false" in opts


def _by_name(objs, kind, name):
    return next(o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name)


def test_console_argo_rbac_scopes_to_applications_for_console_sas():
    objs = _synth()
    role = _by_name(objs, "Role", "tripbot-console-argo")
    assert role["metadata"]["namespace"] == "argocd"
    # applications only — no other Argo CRs / config, no cluster scope
    assert len(role["rules"]) == 1
    rule = role["rules"][0]
    assert rule["apiGroups"] == ["argoproj.io"]
    assert rule["resources"] == ["applications"]
    assert set(rule["verbs"]) == {"get", "list", "watch", "patch"}
    # bound to each minipc console env's ServiceAccount
    rb = _by_name(objs, "RoleBinding", "tripbot-console-argo")
    assert rb["roleRef"]["name"] == "tripbot-console-argo"
    subjects = {(s["name"], s["namespace"]) for s in rb["subjects"]}
    assert subjects == {("tripbot-console", "prod-1"), ("tripbot-console", "stage-1")}


def test_no_console_argo_rbac_on_dev():
    # dev's console isn't Argo-managed (CONSOLE_REVISIONS is prod/stage only), so
    # the dev Argo grants no console→Applications access.
    objs = _synth(**_DEV)
    assert not any(
        o["kind"] in ("Role", "RoleBinding")
        and o["metadata"]["name"] == "tripbot-console-argo"
        for o in objs
    )
