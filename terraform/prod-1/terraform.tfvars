environment = "prod"

primary_domain   = "dana.lol"
secondary_domain = "whereisdana.today"

# other account IDs
core_account_id = "729863845087"

#TODO: move this to random secret
rds_tripbot_username = "tripbot_prod"
rds_tripbot_password = "atone7VEAL3idealize2elvish"

# this is a convention set by middleman
static_site_public_dir = "build"

primary_acm_cert_alternative_names = [
  "www.${var.primary_domain}",
  var.primary_domain
]
