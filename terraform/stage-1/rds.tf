resource "aws_db_instance" "tripbot" {
  # only create on stage for now
  count = var.environment == "stage" ? 1 : 0

  engine         = "postgres"
  engine_version = "11.10"
  instance_class = "db.t2.micro"

  identifier = "tripbot-db"
  name       = "tripbot"
  username   = var.rds_tripbot_username
  password   = var.rds_tripbot_password

  allocated_storage = 20
  storage_type      = "gp2" # general purpose SSD
  # storage_encrypted = true

  # enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  publicly_accessible    = true
  vpc_security_group_ids = [aws_security_group.allow_postgres.id]
  #db_subnet_group_name   = module.vpc.database_subnet_group

  backup_retention_period   = 30
  final_snapshot_identifier = "tripbot-db-final-snapshot"
}

resource "aws_security_group" "allow_postgres" {
  name        = "allow-postgres"
  description = "This group allows Postgres connections"
  vpc_id      = module.default_vpc.vpc_id

  ingress {
    description = "Postgres from shadyglen"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["172.3.109.123/32"]
  }

  ingress {
    description = "Postgres from hawthorne"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["68.239.30.152/32"]
  }

  ingress {
    description = "Postgres from aarons"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["73.16.124.8/32"]
  }

  #TODO: associate an elastic IP
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
