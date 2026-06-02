"""Config-literal blocks shared by the Go services (vlc-server + tripbot share
one config package, so they share env-var surface). Kept here so the two
constructs assemble identical telemetry/stub blocks instead of drifting.
"""
from __future__ import annotations

from adanalife_k8s.config import EnvConfig


def telemetry_config(env: EnvConfig) -> dict[str, str]:
    """ENV + OTEL_* + SENTRY_ENVIRONMENT — the per-env telemetry block both
    services merge onto their base ConfigMap."""
    return {
        "ENV": env.binary_env,
        "OTEL_SDK_DISABLED": env.otel_disabled,
        "OTEL_TRACES_SAMPLER": "parentbased_traceidratio",
        "OTEL_TRACES_SAMPLER_ARG": "0.1",
        "OTEL_RESOURCE_ATTRIBUTES": f"deployment.environment={env.deployment_env},service.namespace=tripbot",
        "SENTRY_ENVIRONMENT": env.sentry_env,
    }


def local_stubs() -> dict[str, str]:
    """DB / Twitch / Twilio stub values the local overlay injects (and that the
    development overlay inherits by extending local). Absent on stage/prod,
    where the real values arrive via ESO Secrets."""
    return {
        "DATABASE_HOST": "postgres",
        "DATABASE_USER": "tripbot_docker",
        "DATABASE_PASS": "hunter2",
        "DATABASE_DB": "tripbot_docker",
        "CHANNEL_NAME": "adanalife",
        "BOT_USERNAME": "adanalife_bot",
        "TWITCH_CLIENT_ID": "stub",
        "TWITCH_CLIENT_SECRET": "stub",
        "TWITCH_AUTH_TOKEN": "oauth:stub",
        "TWILIO_ACCT_SID": "stub",
        "TWILIO_AUTH_TOKEN": "stub",
        "TWILIO_FROM_NUM": "+15555550100",
        "TWILIO_TO_NUM": "+15555550101",
    }


def uses_local_stubs(env: EnvConfig) -> bool:
    """Local + development carry the stub block (development extends local)."""
    return env.name in ("local", "development")
