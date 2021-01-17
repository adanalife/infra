output default_vpc_cidr {
  description = "The CIDR block of the entire VPC"
  value       = module.default_vpc.default_vpc_cidr_block
}

output default_vpc_id {
  description = "The VPC ID of the default VPC"
  value       = module.default_vpc.default_vpc_id
}

output route53_name_servers {
  value = aws_route53_zone.subdomain_zone.name_servers
}

output route53_zone_id {
  value = aws_route53_zone.subdomain_zone.zone_id
}

output rds_tripbot_db_address {
  value = aws_db_instance.tripbot.address
}
