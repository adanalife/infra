# these are used when creating new accounts
# i.e. danadotlol+account_name@gmail.com
email_prefix = "danadotlol+"
email_domain = "gmail.com"

domain           = "dana.lol"
secondary_domain = "whereisdana.today"

# this is where the core accounts Terraform state will live
state_bucket = "adanalife-core-tf-state"

# note that the order of these matters, and if you remove them
# you will have to manually mess with the terraform state
account_names = [
  "stage-1",
  "prod-1"
]

# these are obtained after running Terraform on stage
primary_stage_nameservers = [
  "ns-1278.awsdns-31.org",
  "ns-1619.awsdns-10.co.uk",
  "ns-498.awsdns-62.com",
  "ns-906.awsdns-49.net",
]

# these are obtained after running Terraform on stage
secondary_stage_nameservers = [
  "ns-1509.awsdns-60.org",
  "ns-1546.awsdns-01.co.uk",
  "ns-284.awsdns-35.com",
  "ns-816.awsdns-38.net",
]

# these are obtained after running Terraform on prod
primary_prod_nameservers = [
  "ns-1301.awsdns-34.org",
  "ns-1813.awsdns-34.co.uk",
  "ns-293.awsdns-36.com",
  "ns-772.awsdns-32.net",
]

# these are obtained after running Terraform on prod
secondary_prod_nameservers = [
  "ns-1487.awsdns-57.org",
  "ns-1548.awsdns-01.co.uk",
  "ns-326.awsdns-40.com",
  "ns-798.awsdns-35.net",
]

# these come from the ACM page on prod
primary_www_acm_dns_name   = "_8648ab8ec2619662cf8cab0fcbd7e4bf.www.dana.lol."
primary_www_acm_dns_record = "_5c4c1563d4296f6f72aff30f7e5779f9.vtqfhvjlcp.acm-validations.aws."

# these come from the ACM page on prod
primary_naked_acm_dns_name   = "_942d58be16fbe12ca6b55b2c4729d7a9.dana.lol."
primary_naked_acm_dns_record = "_466cddc22b97c9c41ea57c0adf6a26a5.vtqfhvjlcp.acm-validations.aws."
