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


def test_minipc_default_has_both_uis_and_both_envs():
    objs = _synth()
    classes = {
        o["spec"].get("ingressClassName") for o in objs if o["kind"] == "Ingress"
    }
    assert classes == {"tailscale", "traefik"}  # tailnet UI + LAN UI
    envs = {
        e["env"]
        for e in _appset(objs, "tripbot-apps")["spec"]["generators"][0]["list"][
            "elements"
        ]
    }
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
    # dev runs only the per-repo tripbot + infra projects (no console/video-pipeline)
    assert {o["metadata"]["name"] for o in objs if o["kind"] == "AppProject"} == {
        "tripbot",
        "infra",
    }
    for name in ("tripbot", "infra"):
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
    ):
        assert _appset(objs, appset)["spec"]["template"]["spec"]["project"] == project
    # cluster-resource whitelists are scoped to what each repo's dist actually
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
    assert dests("video-pipeline") == {"stage-1"}
    assert dests("platform-gateway") == {"prod-1", "stage-1"}


def test_minipc_apps_autosync_except_prod_obs():
    objs = _synth()
    patch = _appset(objs, "tripbot-apps")["spec"]["templatePatch"]
    # both minipc envs are automated...
    assert '(eq .env "stage-1")' in patch
    assert '(eq .env "prod-1")' in patch
    # ...except prod OBS, carved back out (a sync restarts the live stream)
    assert '(not (and (eq .env "prod-1") (eq .app "obs-twitch")))' in patch
    # selfHeal is per-env: stage is OFF (a hand/console scale sticks so
    # components can be parked at 0 to free the minipc), prod stays ON (the live
    # stream must match git). Both branches render in the goTemplate conditional.
    assert '{{- if (eq .env "stage-1") }}' in patch
    assert "selfHeal: false" in patch
    assert "selfHeal: true" in patch
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
        # prod rides master (release-gated); stage + dev ride develop
        revs = {e["env"]: e["revision"] for e in elements}
        assert revs.get("prod-1", "master") == "master"
        assert all(v == "develop" for k, v in revs.items() if k != "prod-1")


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


def test_video_pipeline_appset_stage_only_cross_repo():
    objs = _synth()
    vp = _appset(objs, "video-pipeline")
    elements = vp["spec"]["generators"][0]["list"]["elements"]
    assert {e["env"] for e in elements} == {"stage-1"}  # stage-only today
    src = vp["spec"]["template"]["spec"]["source"]
    assert src["repoURL"] == "git@github.com:adanalife/video-pipeline.git"
    # exact-match include: the persistent unit, not the sibling -jobs file
    assert src["directory"]["include"] == "{{.env}}.k8s.yaml"
    assert "automated" in vp["spec"]["templatePatch"]  # stage autosyncs
    # dev cluster carries no private-repo deploy key, so no video-pipeline unit
    with pytest.raises(StopIteration):
        _appset(_synth(**_DEV), "video-pipeline")


def test_platform_gateway_appset_both_envs_cross_repo():
    objs = _synth()
    pg = _appset(objs, "platform-gateway")
    revs = {
        e["env"]: e["revision"] for e in pg["spec"]["generators"][0]["list"]["elements"]
    }
    # both prod + stage run twitch-api; prod pins master, stage floats develop
    assert revs == {"prod-1": "master", "stage-1": "develop"}
    src = pg["spec"]["template"]["spec"]["source"]
    assert src["repoURL"] == "git@github.com:adanalife/platform-gateway.git"
    assert src["directory"]["include"] == "{{.env}}.k8s.yaml"
    assert "automated" in pg["spec"]["templatePatch"]  # autosyncs like the others
    # dev cluster carries no private-repo deploy key, so no platform-gateway unit
    with pytest.raises(StopIteration):
        _appset(_synth(**_DEV), "platform-gateway")


def test_data_appset_never_prunes_either_variant():
    for kwargs in ({}, _DEV):
        data = _appset(_synth(**kwargs), "tripbot-data")
        opts = data["spec"]["template"]["spec"]["syncPolicy"]["syncOptions"]
        assert "Prune=false" in opts
