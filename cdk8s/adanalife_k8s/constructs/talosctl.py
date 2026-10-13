"""The talosctl client the node-reading constructs share (ups_monitor,
t5_watchdog, kmsg): which node they address, which client they fetch, and where
it and the talosconfig sit in the pod.

One pin for all three, matched to the node's Talos version: a client older than
the node it talks to is the drift this module exists to rule out.
"""

# The minipc Talos node: control plane, etcd, the T5, and the one UPS-backed box.
TALOS_NODE = "192.168.40.111"
# The initContainer fetches the client binary at pod start (the Python image
# doesn't ship it); a long-lived pod fetches once. amd64, the minipc's arch.
TALOSCTL_VERSION = "v1.14.0"
TALOSCTL_URL = (
    f"https://github.com/siderolabs/talos/releases/download/{TALOSCTL_VERSION}"
    "/talosctl-linux-amd64"
)
TALOSCTL_PATH = "/opt/talos/talosctl"  # placed by the initContainer
TALOSCONFIG_PATH = "/talos/talosconfig"  # mounted from the (optional) Secret

# initContainer: fetch the pinned talosctl into the shared volume, with stdlib
# urllib from the python image each construct runs. Verified-by-pin, not
# checksum — acceptable for LAN-only helpers; revisit if supply-chain hardening
# is wanted.
FETCH_TALOSCTL = """\
import os
import urllib.request

url = os.environ["TALOSCTL_URL"]
dst = os.environ["TALOSCTL_PATH"]
print(f"fetching {url}", flush=True)
urllib.request.urlretrieve(url, dst)
os.chmod(dst, 0o755)
print(f"talosctl -> {dst}", flush=True)
"""
