"""Pytest fixtures for the post-apply integration suite.

These tests run AGAINST A LIVE CLUSTER (after `kubectl apply` / `task k8s:<env>:apply`)
and assert the synthesized workloads actually came up. They are the verification
harness for the Kustomize -> cdk8s migration cutover — distinct from the synth-time
unit tests under tests/unit/ (which never touch a cluster).

Safe to run anywhere: if no cluster is reachable, or the target namespace doesn't
exist, the whole suite SKIPS rather than erroring. CI without a cluster just skips.

Run against a real env::

    mise exec -- uv run pytest tests/integration --env stage-1

after `task k8s:stage:apply`. The default --env is stage-1.

The expected-workload matrix is derived from adanalife_k8s.config.load_env (the same
EnvConfig the charts synth from) and adanalife_k8s.contract.load_contract (canonical
service names/ports), so it can't drift from what was actually deployed.
"""

from __future__ import annotations

import pytest

from adanalife_k8s.config import ENVS, load_env
from adanalife_k8s.contract import load_contract

# kubernetes client import is deferred-tolerant: if it (or kubeconfig) is missing
# we still want collection to succeed and the suite to skip, not error.
try:
    from kubernetes import client, config
    from kubernetes.config.config_exception import ConfigException

    _KUBERNETES_IMPORT_ERROR = None
except Exception as exc:  # pragma: no cover - only on a broken install
    client = None  # type: ignore[assignment]
    config = None  # type: ignore[assignment]
    ConfigException = Exception  # type: ignore[assignment,misc]
    _KUBERNETES_IMPORT_ERROR = exc


# --------------------------------------------------------------------------- #
# pytest options
# --------------------------------------------------------------------------- #
def pytest_addoption(parser):
    parser.addoption(
        "--env",
        action="store",
        default="stage-1",
        choices=sorted(ENVS),
        help="which adanalife env (namespace) to assert against (default: stage-1)",
    )


# --------------------------------------------------------------------------- #
# cluster reachability — the gate that makes the suite safe to run anywhere
# --------------------------------------------------------------------------- #
def _load_kube() -> str | None:
    """Load kubeconfig and confirm the apiserver answers.

    Returns None on success, or a human-readable reason string when the cluster
    is unreachable / unconfigured — the caller turns that into a skip.
    """
    if _KUBERNETES_IMPORT_ERROR is not None:
        return f"kubernetes client unavailable: {_KUBERNETES_IMPORT_ERROR}"
    try:
        config.load_kube_config()
    except ConfigException as exc:
        return f"no usable kubeconfig: {exc}"
    except Exception as exc:  # FileNotFoundError etc.
        return f"could not load kubeconfig: {exc}"
    # A cheap call that forces an actual round-trip to the apiserver.
    try:
        client.VersionApi().get_code(_request_timeout=5)
    except Exception as exc:
        return f"cluster unreachable: {exc}"
    return None


@pytest.fixture(scope="session")
def cluster_reachable() -> None:
    """Skip the whole session if no cluster answers."""
    reason = _load_kube()
    if reason is not None:
        pytest.skip(reason, allow_module_level=True)


@pytest.fixture(scope="session")
def env_name(request) -> str:
    return request.config.getoption("--env")


@pytest.fixture(scope="session")
def env_config(env_name):
    return load_env(env_name)


@pytest.fixture(scope="session")
def namespace(env_config) -> str:
    return env_config.namespace


@pytest.fixture(scope="session")
def contract():
    return load_contract()


@pytest.fixture(scope="session")
def core_v1(cluster_reachable):
    return client.CoreV1Api()


@pytest.fixture(scope="session")
def apps_v1(cluster_reachable):
    return client.AppsV1Api()


@pytest.fixture(scope="session")
def networking_v1(cluster_reachable):
    return client.NetworkingV1Api()


@pytest.fixture(scope="session")
def namespace_exists(cluster_reachable, core_v1, namespace) -> None:
    """Skip the whole session if the target namespace isn't present — e.g. the
    env was never applied to this cluster. Distinguishes "cluster up but env not
    deployed" from "no cluster at all"."""
    from kubernetes.client.rest import ApiException

    try:
        core_v1.read_namespace(namespace)
    except ApiException as exc:
        if exc.status == 404:
            pytest.skip(
                f"namespace {namespace!r} not found on this cluster "
                f"(env not applied here?)",
                allow_module_level=True,
            )
        raise


# --------------------------------------------------------------------------- #
# expected-workload matrix (derived, not hardcoded)
# --------------------------------------------------------------------------- #
@pytest.fixture(scope="session")
def expected(env_config, contract):
    """The objects the app charts synthesize for this env, by canonical name.

    Mirrors adanalife_k8s/charts.py emit_app_charts: one Deployment + Service per
    (component, platform) for tripbot/vlc/onscreens/obs — each named
    <component>-<platform> via the contract — plus the shared postgres
    StatefulSet. Ingresses with a LB address only exist on minipc envs.
    """
    svc = contract.svc
    platforms = env_config.platforms
    components = ("tripbot", "vlc", "onscreens", "obs")

    # one Deployment + Service per (component, platform)
    deployments = [svc(f"{c}_{p}") for p in platforms for c in components]
    services = deployments + [svc("postgres")]

    # Ingresses we expect a load-balancer address on (external-dns / traefik).
    # Only the minipc clusters (stage-1, prod-1) carry app Ingresses; dev has a
    # vlc Ingress but no LB-IP machinery worth asserting, local has none. tripbot
    # + vlc carry the LB-addressed Ingresses per platform (onscreens is internal).
    lb_ingresses = []
    if env_config.cluster == "minipc":
        lb_ingresses = [svc(f"{c}_{p}") for p in platforms for c in ("vlc", "tripbot")]

    return {
        "deployments": deployments,
        "statefulsets": [svc("postgres")],
        "services": services,
        "lb_ingresses": lb_ingresses,
    }
