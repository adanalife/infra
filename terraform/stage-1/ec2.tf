resource aws_security_group allow_ssh {
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

  ingress {
    description = "SSH from hawthorne"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["108.49.156.172/32"]
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

resource aws_key_pair dana {
  key_name   = "dmerrick-v1"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCuiO/+UBZ1yX+R4H6hWSBhJ88cNpVuGMhL6nVfJbKmFlM+q1IsHc20FbEwWRCJQxSDAZD+PlxCZierBp5L3XOzoJAfNFTimo+D2GhcYIek5nK2S0jcfKcyVchLXfLGO8seqZKwNr1aWRv8Wujri9lK2sC4N33WvYDcQQJqTWMuVJig0qRiLGwj1ajZPAZgZrlUdbuXOG2Zizcvv4OxaJY/q1X+Zlyu4+qhHjY/9+UM3znoVkgoEFeiNDipjANzbtu2WnlM7Hz0UKhPNlHqWr1qKtENYwHN9JDX3QO2/PBzHNZmCkJKSYEWFP8BHeKk9PbvGcjkSE0k3b4UWKMdUO+NXCxltyNWpZyzatKsNXiQgq7KPUclwrmb1YjU3iFdbuM9a+fSWLg4K/E9BDcKTxBVyIdxo5puTbMXFFFWl/w8IFJS93rh2eh44ISvP/e3E+fpFoSIRqDM3gYPOIbB9N9I+89HJGg8Po0MESajDkTw7KNDMdnAXMe8QgO+7xA30bE="
}
