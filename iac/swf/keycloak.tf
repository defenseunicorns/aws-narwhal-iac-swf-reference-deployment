locals {
  keycloak_db_secret_name            = join("-", compact([local.prefix, "keycloak-db-secret", local.suffix]))
  keycloak_kms_key_alias_name_prefix = join("-", compact([local.prefix, var.keycloak_kms_key_alias, local.suffix]))
}

module "keycloak_kms_key" {
  source = "github.com/defenseunicorns/terraform-aws-uds-kms?ref=v0.0.6"

  kms_key_alias_name_prefix = local.keycloak_kms_key_alias_name_prefix
  kms_key_deletion_window   = 7
  kms_key_description       = "Keycloak Key"
}

# RDS

resource "random_password" "keycloak_db_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "keycloak_db_secret" {
  name                    = local.keycloak_db_secret_name
  description             = "Keycloak DB authentication token"
  recovery_window_in_days = var.recovery_window
  kms_key_id              = module.keycloak_kms_key.kms_key_arn
}

module "keycloak_db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.10.0"
  tags    = local.tags

  identifier                     = var.keycloak_db_idenitfier_prefix
  instance_use_identifier_prefix = true

  allocated_storage       = 20
  max_allocated_storage   = 500
  backup_retention_period = 30
  backup_window           = "03:00-06:00"
  maintenance_window      = "Mon:00:00-Mon:03:00"

  engine               = "postgres"
  engine_version       = "15.6"
  major_engine_version = "15"
  family               = "postgres15"
  instance_class       = var.keycloak_rds_instance_class

  db_name  = var.keycloak_db_name
  username = "keycloak"
  port     = "5432"

  # Restoring from a snapshot
  snapshot_identifier = var.keycloak_db_snapshot

  subnet_ids                  = module.vpc.database_subnets
  db_subnet_group_name        = module.vpc.database_subnet_group_name
  manage_master_user_password = false
  password                    = random_password.keycloak_db_password.result

  multi_az = false

  copy_tags_to_snapshot = true

  allow_major_version_upgrade = false
  auto_minor_version_upgrade  = false

  deletion_protection = var.rds_deletion_protection

  vpc_security_group_ids = [aws_security_group.keycloak_rds_sg.id]
}

resource "aws_security_group" "keycloak_rds_sg" {
  vpc_id = module.vpc.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_rds_ingress" {
  security_group_id = aws_security_group.keycloak_rds_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 0
  to_port     = 5432
}
