# Stable LAN endpoints for the adanalife-minipc Talos cluster, plus a single
# mutable pointer the in-cluster external-dns + traefik target.
#
# The minipc is portable — it moves between physical networks. The old approach
# re-stamped every app record's target on each move: `task k8s:<env>:bootstrap-
# secrets` discovered the node InternalIP and wrote it into per-machine helm
# values (and once silently grabbed the Tailscale interface IP, gating prod
# behind Tailscale). Instead, external-dns now targets the stable name
# `minipc.whereisdana.today` forever, and that CNAME points at whichever
# per-location A record is active. A move is a one-line change here
# (`var.minipc_active_location`) + `task tf:core:apply` — no cluster touch, no
# per-record churn.
#
# These live in the whereisdana.today (secondary) apex zone — the parent of the
# prod/stage delegated subdomains — so prod-1 and stage-1 external-dns share one
# pointer. external-dns never manages them (its domainFilter is the prod/stage
# subdomain, not the bare apex), so there's no ownership conflict.
#
# The LAN IPs resolve publicly to private addresses: reachable on their home
# network directly, and off-LAN via the Tailscale subnet route.

locals {
  # Per-location LAN IP of the minipc node. Add a row when the box lands on a new
  # network; the map key is the Route53 label under whereisdana.today.
  minipc_location_ips = {
    "tallman-local"   = "192.168.40.111" # current network
    "shadyglen-local" = "192.168.1.200"  # Texas network
  }
}

# One stable A record per known location.
resource "aws_route53_record" "minipc_location" {
  for_each = local.minipc_location_ips

  zone_id = aws_route53_zone.secondary.zone_id
  name    = "${each.key}.${aws_route53_zone.secondary.name}"
  type    = "A"
  ttl     = 300
  records = [each.value]
}

# The mutable pointer external-dns (--default-targets) + traefik
# (ingressEndpoint.hostname) aim at. Flip var.minipc_active_location to repoint
# every app record in one move. Referencing the A record by map key means an
# unknown location fails at plan time. Low TTL so a move propagates fast.
resource "aws_route53_record" "minipc_pointer" {
  zone_id = aws_route53_zone.secondary.zone_id
  name    = "minipc.${aws_route53_zone.secondary.name}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_route53_record.minipc_location[var.minipc_active_location].name]
}
