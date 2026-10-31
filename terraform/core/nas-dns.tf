# Stable LAN endpoint for the Synology NAS (the dashcam-corpus NFS server),
# mirroring the minipc pointer pattern in minipc-dns.tf.
#
# The NAS is portable in lockstep with the minipc — the cluster mounts the
# dashcam corpus from it over LAN NFS, so the two boxes are always on the same
# physical network. Rather than re-stamping the NFS server IP in the gitignored
# vlc-server dashcam-nfs overlays on every move, point those at the stable name
# `nas.whereisdana.today`, which resolves to whichever per-location A record is
# active. Because the NAS rides the same move as the minipc, it shares the
# single `var.minipc_active_location` toggle — flip that one variable and both
# pointers repoint together.
#
# These live in the whereisdana.today (secondary) apex zone alongside the minipc
# records. external-dns never manages them (its domainFilter is the prod/stage
# subdomain, not the bare apex), so there's no ownership conflict.
#
# The LAN IPs resolve publicly to private addresses: reachable on their home
# network directly, and off-LAN via the Tailscale subnet route.

locals {
  # Per-location LAN IP of the NAS. Keys match local.minipc_location_ips so the
  # shared var.minipc_active_location toggle selects both.
  nas_location_ips = {
    "tallman-local"   = "192.168.40.100" # current network (Maine)
    "shadyglen-local" = "192.168.1.222"  # Texas network
  }
}

# One stable A record per known location.
resource "aws_route53_record" "nas_location" {
  for_each = local.nas_location_ips

  zone_id = aws_route53_zone.secondary.zone_id
  name    = "nas-${each.key}.${aws_route53_zone.secondary.name}"
  type    = "A"
  ttl     = 300
  records = [each.value]
}

# The mutable pointer the dashcam-nfs overlays aim at. Shares
# var.minipc_active_location with the minipc pointer since the NAS always moves
# with the minipc. Low TTL so a move propagates fast.
resource "aws_route53_record" "nas_pointer" {
  zone_id = aws_route53_zone.secondary.zone_id
  name    = "nas.${aws_route53_zone.secondary.name}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_route53_record.nas_location[var.minipc_active_location].name]
}
