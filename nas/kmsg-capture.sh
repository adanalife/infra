#!/bin/sh
# Capture the Talos node's kernel log onto the Synology.
#
# Talos does not persist dmesg across a reboot, so a node that dies takes its
# own explanation with it — six deaths on 2026-08-23 produced no kernel evidence
# between them, after memory, CPU and disk had all been measured clean. Reading
# the log live and writing it somewhere else is what makes the next one
# diagnosable.
#
# It runs HERE, off the node, for one reason: an in-cluster receiver dies with
# the thing it is watching. The trade is that the NAS is itself a single point of
# failure (one LAN interface, 34,260 link-down events) — so this is best-effort
# by design. A capture that misses some crashes still beats no capture, because
# the node has been failing repeatedly rather than once.
#
# Deliberately does NOT use Talos's KmsgLogConfig, which would ship kmsg to a
# listener. That needs a control-plane `talosctl apply-config`, and a certSAN
# edit took both databases down on 2026-06-15 — so the whole class of risk is
# avoided by reading the API instead of reconfiguring the node.
#
# Install (see nas/README.md): the talosctl binary, an os:reader talosconfig,
# and this script, then a DSM Task Scheduler entry triggered on Boot-up.

set -eu

BASE="${KMSG_BASE:-/volume1/ADanaLife/kmsg}"
BIN="$BASE/talosctl"
CFG="$BASE/talosconfig"
DIR="$BASE/logs"
NODE="${KMSG_NODE:-minipc.whereisdana.today}"
# Days of logs to keep. The kernel log of an idle node is small; a misbehaving
# one is not, and this script must never be the reason the volume fills.
RETAIN_DAYS="${KMSG_RETAIN_DAYS:-14}"
# Pause before reattaching. Long enough not to spin while the node is down,
# short enough to be attached again well before it finishes booting.
RECONNECT_WAIT="${KMSG_RECONNECT_WAIT:-10}"

# Always UTC. DSM's local timezone is Central while the cluster logs UTC, and
# correlating a crash against Grafana across a silent one-hour offset is exactly
# the kind of mistake that costs an afternoon.
stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

mkdir -p "$DIR"

while :; do
  log="$DIR/kmsg-$(date -u '+%Y-%m-%d').log"

  # The attach/detach markers are the point, not decoration. `dmesg --follow`
  # ends when the node stops answering, so a DETACHED line followed by an
  # ATTACHED one brackets the moment the node went away — which is the event
  # being hunted, and the only timestamp for it that survives the reboot.
  echo "=== kmsg-capture ATTACHED $(stamp) node=$NODE ===" >>"$log"

  # Not fatal: the node being unreachable is the normal case this loop exists
  # to survive, so `set -e` must not end the capture when it happens.
  TALOSCONFIG="$CFG" "$BIN" --nodes "$NODE" dmesg --follow >>"$log" 2>&1 || true

  echo "=== kmsg-capture DETACHED $(stamp) (node unreachable or stream closed) ===" >>"$log"

  # Each reattach re-dumps the whole ring buffer, so a boot's early lines can
  # appear more than once after a network blip. Left as duplication rather than
  # deduplicated: after a real reboot the buffer is genuinely new, and telling
  # the two cases apart is the analysis, not the capture's job.
  find "$DIR" -name 'kmsg-*.log' -type f -mtime "+$RETAIN_DAYS" -delete 2>/dev/null || true

  sleep "$RECONNECT_WAIT"
done
