# to see these values at any time, run:
#   $ terraform output

output accounts {
  value = merge(
    zipmap(aws_organizations_account.account.*.name, aws_organizations_account.account.*.id),
    { "${local.account_name}" = local.core_account_id }
  )
}

output primary_route53_zone_id {
  value = aws_route53_zone.primary.zone_id
}

output primary_route53_name_servers {
  value = aws_route53_zone.primary.name_servers
}

output secondary_route53_zone_id {
  value = aws_route53_zone.secondary.zone_id
}

output secondary_route53_name_servers {
  value = aws_route53_zone.secondary.name_servers
}
