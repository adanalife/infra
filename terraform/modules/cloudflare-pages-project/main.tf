# A Cloudflare Pages project, its custom domains, and optionally the
# orange-cloud CNAME that fronts one of them.
#
# The dana.lol site ships one of these per environment
# (terraform/{stage-1,prod-1}/cloudflare-pages.tf). The environments differ
# only in which hostnames they bind and in whether Cloudflare is authoritative
# for any of them, which is what the two optional inputs cover.

resource "cloudflare_pages_project" "this" {
  account_id = var.account_id
  name       = var.project_name

  production_branch = var.production_branch

  # Direct Upload — no `source` block. Every deploy goes through
  # `wrangler pages deploy` from GitHub Actions, so the Cloudflare → GitHub
  # App integration is dead weight, and an unhealthy install throws 401 (CF
  # error 8000011) on apply.
  #
  # dana-lol-staging was created with a GitHub source block, back when
  # develop→master used CF Pages auto-deploys, and Cloudflare's API refuses to
  # unset it: a PATCH with {"source": null} returns success, but the source is
  # still there on the next plan, and the dashboard's "Disconnect" UI is hidden
  # because the GitHub App install sits in the unhealthy state behind that same
  # 8000011. So the dead block stays attached and does nothing.
  #
  # A project that never had a source carries none in state, so ignoring the
  # attribute is a no-op there rather than a suppressed diff.
  lifecycle {
    ignore_changes = [source]
  }
}

resource "cloudflare_pages_domain" "this" {
  for_each = toset(var.domains)

  account_id   = var.account_id
  project_name = cloudflare_pages_project.this.name
  name         = each.value
}

# Pages requires the proxy on for custom-domain TLS to work, so the CNAME that
# resolves the hostname is also what lets Universal SSL front the Pages origin.
resource "cloudflare_dns_record" "this" {
  count = var.dns_record == null ? 0 : 1

  zone_id = var.dns_record.zone_id
  name    = var.dns_record.name
  type    = "CNAME"
  ttl     = 1 # 1 = auto when proxied
  proxied = true
  content = "${cloudflare_pages_project.this.name}.pages.dev"
}
