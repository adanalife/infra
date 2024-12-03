resource "aws_security_group" "allow_ssh" {
  name        = "allow-ssh"
  description = "This group allows SSH connections"
  vpc_id      = module.default_vpc.vpc_id

  ingress {
    description = "SSH from shadyglen"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["172.3.109.123/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow-ssh"
  }
}

resource "aws_security_group" "allow_tripbot_access" {
  name        = "allow-tripbot-access"
  description = "This group allows access to tripbot's HTTP server"
  vpc_id      = module.default_vpc.vpc_id

  ingress {
    description = "HTTP from everywhere"
    from_port   = 4569
    to_port     = 4569
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow-tripbot-access"
  }
}

#TODO: remove this when it's no longer referenced
resource "aws_key_pair" "dana" {
  key_name   = "dmerrick-v1"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCuiO/+UBZ1yX+R4H6hWSBhJ88cNpVuGMhL6nVfJbKmFlM+q1IsHc20FbEwWRCJQxSDAZD+PlxCZierBp5L3XOzoJAfNFTimo+D2GhcYIek5nK2S0jcfKcyVchLXfLGO8seqZKwNr1aWRv8Wujri9lK2sC4N33WvYDcQQJqTWMuVJig0qRiLGwj1ajZPAZgZrlUdbuXOG2Zizcvv4OxaJY/q1X+Zlyu4+qhHjY/9+UM3znoVkgoEFeiNDipjANzbtu2WnlM7Hz0UKhPNlHqWr1qKtENYwHN9JDX3QO2/PBzHNZmCkJKSYEWFP8BHeKk9PbvGcjkSE0k3b4UWKMdUO+NXCxltyNWpZyzatKsNXiQgq7KPUclwrmb1YjU3iFdbuM9a+fSWLg4K/E9BDcKTxBVyIdxo5puTbMXFFFWl/w8IFJS93rh2eh44ISvP/e3E+fpFoSIRqDM3gYPOIbB9N9I+89HJGg8Po0MESajDkTw7KNDMdnAXMe8QgO+7xA30bE="
}

resource "aws_key_pair" "dmerrick_v2" {
  key_name   = "dmerrick-v2"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGdKRZZEFZxXt8S7rodB0EWD9TnuEarT7CzNjcdoKiaY"
}

# this is the old, prod tripbot
#TODO: remove this when it's no longer referenced
resource "aws_instance" "tripbot" {
  # only create on prod for now
  count = var.environment == "prod" ? 1 : 0

  ami           = "ami-0c3e87333771b10a6" # ubuntu 21.04
  instance_type = "t3.micro"              # free tier
  key_name      = aws_key_pair.dana.key_name

  security_groups = [
    aws_security_group.allow_ssh.name,
    aws_security_group.allow_tripbot_access.name,
  ]

  #TODO: move this to VPC
  associate_public_ip_address = true
  #disable_api_termination     = true

  tags = {
    "Name" = "Tripbot server"
  }
}

resource "aws_instance" "tripbot_server" {
  # only create on stage for now
  count = var.environment == "stage" ? 1 : 0

  ami           = "ami-0c3e87333771b10a6" # ubuntu 24.04
  instance_type = "t3.micro"              # free tier
  key_name      = aws_key_pair.dmerrick_v2.key_name

  security_groups = [
    aws_security_group.allow_ssh.name,
    aws_security_group.allow_tripbot_access.name,
  ]

  #TODO: move this to VPC
  associate_public_ip_address = true
  #disable_api_termination     = true

  tags = {
    "Name" = "Tripbot server (${var.environment})"
  }
}

output "tripbot_ip_address" {
  value     = var.environment == "stage" ? aws_instance.tripbot_server[0].public_dns : aws_instance.tripbot[0].public_dns
  sensitive = true
}
