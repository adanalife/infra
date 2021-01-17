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
  "stage-1"
]

# these are obtained after running Terraform on stage
primary_stage_nameservers = [
  "ns-1201.awsdns-22.org",
  "ns-14.awsdns-01.com",
  "ns-1760.awsdns-28.co.uk",
  "ns-592.awsdns-10.net",
]

# these are obtained after running Terraform on stage
secondary_stage_nameservers = [
  "ns-120.awsdns-15.com",
  "ns-1319.awsdns-36.org",
  "ns-2003.awsdns-58.co.uk",
  "ns-609.awsdns-12.net",
]
