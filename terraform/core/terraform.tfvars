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
secondary_stage_nameservers = [
  "ns-1179.awsdns-19.org",
  "ns-1910.awsdns-46.co.uk",
  "ns-433.awsdns-54.com",
  "ns-851.awsdns-42.net",
]
