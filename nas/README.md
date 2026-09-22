# Synology-hosted helpers

Things that run on the Synology (`nas.whereisdana.today`, `192.168.40.100`)
rather than in the cluster.

The NAS is **not** a Kubernetes node and is not going to become one: its Atom
C3538 has roughly a third of the node's single-thread performance, and DSM's
custom kernel plus Container Manager's patched Docker break k3s/k3d installs in
non-obvious ways that DSM upgrades re-break. So anything here is a plain script or a Container
Manager compose file, version-controlled in this repo and copied over — not
orchestrated.

## `kmsg-capture.sh` — the Talos node's kernel log

Talos does not persist `dmesg` across a reboot, so a node that dies takes its own
explanation with it. This reads the kernel log live over the Talos API and
appends it to the NAS, which is the only host involved that survives the node
dying.

It reads the API rather than using Talos's `KmsgLogConfig`, deliberately: that
would need a control-plane `talosctl apply-config`, and a certSAN edit took both
databases down on 2026-06-15. Reading avoids the entire risk class — no node
reconfiguration, and nothing to back up first.

### Install

1. **Mint a read-only credential.** The NAS must never hold a talosconfig that
   can act on the node — `os:reader` can read `dmesg` and nothing else:

   ```sh
   talosctl -n minipc.whereisdana.today config new \
     --roles os:reader --crt-ttl 8760h nas-kmsg.talosconfig
   ```

   Verify the role before shipping it (the role lives in the certificate's
   Organization field, so this needs no private-key handling):

   ```sh
   # expect: subject=O=os:reader
   grep -o 'crt: [A-Za-z0-9+/=]*' nas-kmsg.talosconfig | cut -d' ' -f2 \
     | base64 -d | openssl x509 -noout -subject
   ```

   Do not paste the file's contents anywhere. A previous talosconfig was echoed
   into a terminal transcript and needed rotating.

2. **Place the three files** in `/volume1/ADanaLife/kmsg/` on the NAS —
   `talosctl` (the `linux-amd64` build matching the cluster's Talos version; the
   Atom is x86-64), `talosconfig` (the file from step 1, mode `600`), and
   `kmsg-capture.sh` from this directory.

3. **Run it on boot.** DSM → Control Panel → Task Scheduler → Create →
   Triggered Task → Boot-up, running
   `sh /volume1/ADanaLife/kmsg/kmsg-capture.sh`. The task has to survive DSM
   upgrades being re-applied, so re-check it after one.

   Task Scheduler runs with no `$HOME`, and `talosctl` resolves the
   `TALOSCONFIG` environment variable relative to a home directory — so the
   script passes `--talosconfig` instead. Anything else added here needs the
   same treatment; a missing `$HOME` surfaces as
   `failed to open config file "": $HOME is not defined`.

### Reading the output

Logs land in `/volume1/ADanaLife/kmsg/logs/kmsg-<UTC date>.log`, pruned after 14
days. Timestamps are UTC even though DSM's own logs are Central — correlating a
crash against Grafana across a silent one-hour offset is its own class of
mistake.

The `ATTACHED` / `DETACHED` markers are the useful part. `dmesg --follow` ends
when the node stops answering, so a `DETACHED` line followed by an `ATTACHED`
one brackets the moment the node went away — and that is the only timestamp for
it that survives the reboot:

```sh
grep -E 'ATTACHED|DETACHED' /volume1/ADanaLife/kmsg/logs/kmsg-*.log
```

A single `ABORTED` line and nothing after it means the talosconfig could not be
opened — the capture stops there rather than retrying, because an unusable
config produces instant detaches that read exactly like a node dying in a loop.

What to look for in the lines *before* a `DETACHED`: `usb` disconnects (the
T5 has dropped off the bus before, and the boot cmdline still carries the
`usb-storage.quirks=04e8:61f5:u` workaround), `igen6_edac` reports (the ECC
driver is loaded, so memory errors would surface there), XFS I/O errors, and
anything from the `mce` subsystem.

Each reattach re-dumps the whole ring buffer, so early boot lines can repeat
after a network blip. That is left as duplication on purpose: after a real
reboot the buffer genuinely is new, and telling the two apart is the analysis.

### Rotation

The credential expires one year from minting. Re-mint with step 1 and replace
the file; nothing else changes.
