"""The Kubernetes Event the node watchdogs (t5_watchdog, ups_monitor) leave
before they reboot or shut down the minipc.

The watchdog's own log line about *why* it acted is the record least likely to
survive the action: the last seconds of a pod's stdout before a reboot often
never reach Loki. An Event is written to etcd, which outlives the reboot, and
the cluster's event shipper forwards it once the node is back — so the reason
is still readable after the fact.

`nodeevent.py` ships in each watchdog's ConfigMap beside its main script; the
script imports it at trigger time. Emitting is best-effort with a short
timeout: a failed Event never delays or blocks the action it describes.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

# Pod-side: the Event's involvedObject is the watchdog's own pod (a Node is
# cluster-scoped, and a namespaced Role can't write Events about it).
NODE_EVENT = """\
import datetime
import json
import os
import ssl
import urllib.request

SA = "/var/run/secrets/kubernetes.io/serviceaccount"


def emit(component, reason, message, timeout=5):
    # True when the API accepted the Event. Never raises.
    try:
        with open(f"{SA}/token") as f:
            token = f.read().strip()
        with open(f"{SA}/namespace") as f:
            ns = f.read().strip()
        now = datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        body = {
            "apiVersion": "v1",
            "kind": "Event",
            "metadata": {"generateName": f"{component}-", "namespace": ns},
            "involvedObject": {
                "kind": "Pod",
                "namespace": ns,
                "name": os.environ.get("POD_NAME", component),
            },
            "reason": reason,
            "message": message,
            "type": "Warning",
            "source": {"component": component},
            "firstTimestamp": now,
            "lastTimestamp": now,
            "count": 1,
        }
        host = os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
        port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        req = urllib.request.Request(
            f"https://{host}:{port}/api/v1/namespaces/{ns}/events",
            data=json.dumps(body).encode(),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
        with urllib.request.urlopen(req, timeout=timeout, context=ctx):
            return True
    except Exception as e:
        print(f"event not written: {e}", flush=True)
        return False
"""

NODE_EVENT_FILE = "nodeevent.py"


def event_writer_rbac(
    scope: Construct, name: str, namespace: str, labels: dict[str, str]
) -> None:
    """A ServiceAccount allowed only to create Events in its own namespace."""
    meta = k8s.ObjectMeta(name=name, namespace=namespace, labels=labels)
    k8s.KubeServiceAccount(scope, "event-sa", metadata=meta)
    k8s.KubeRole(
        scope,
        "event-role",
        metadata=meta,
        rules=[k8s.PolicyRule(api_groups=[""], resources=["events"], verbs=["create"])],
    )
    k8s.KubeRoleBinding(
        scope,
        "event-rolebinding",
        metadata=meta,
        role_ref=k8s.RoleRef(
            api_group="rbac.authorization.k8s.io", kind="Role", name=name
        ),
        subjects=[k8s.Subject(kind="ServiceAccount", name=name, namespace=namespace)],
    )


# Downward API: names the pod the Event is about.
POD_NAME_ENV = k8s.EnvVar(
    name="POD_NAME",
    value_from=k8s.EnvVarSource(
        field_ref=k8s.ObjectFieldSelector(field_path="metadata.name")
    ),
)
