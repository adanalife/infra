resource "random_password" "tripbot_db" {
  length  = 32
  special = false
}

resource "aws_security_group" "allow_postgres" {
  name        = "allow-postgres"
  description = "This group allows Postgres connections"
  vpc_id      = aws_default_vpc.default.id

  ingress {
    description = "Postgres from tripbot"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["3.82.196.113/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow-postgres"
  }
}
