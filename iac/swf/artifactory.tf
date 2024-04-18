locals {
  artifactory_db_secret_name            = join("-", compact([local.prefix, "artifactory-db-secret", local.suffix]))
  artifactory_kms_key_alias_name_prefix = join("-", compact([local.prefix, var.artifactory_kms_key_alias, local.suffix]))
  artifactory_dlm_role_name             = join("-", compact([local.prefix, "dlm-lifecycle-artifactory", local.suffix]))
}

module "artifactory_kms_key" {
  source = "github.com/defenseunicorns/terraform-aws-uds-kms?ref=v0.0.3"

  kms_key_alias_name_prefix = local.artifactory_kms_key_alias_name_prefix
  kms_key_deletion_window   = 7
  kms_key_description       = "Artifactory Key"
}

module "artifactory_volume_snapshots" {
  source        = "./modules/volume-snapshot"
  dlm_role_name = local.artifactory_dlm_role_name

  schedule_details = [{
    name = "Daily"
    create_rule = {
      cron_expression = "cron(0 0 * * ? *)"
    }
    retain_rule = {
      count = 30
    }
    },
    {
      name = "Weekly"
      create_rule = {
        cron_expression = "cron(0 0 ? * 1 *)"
      }
      retain_rule = {
        count = 52
      }
    },
    {
      name = "Monthly"
      create_rule = {
        cron_expression = "cron(0 0 1 * ? *)"
      }
      retain_rule = {
        count = 84
      }
  }]
  target_tags = {
    NamespaceAndId = "artifactory-${lower(random_id.default.hex)}"
  }
  lifecycle_policy_description = "Policy for Artifactory volume snapshots"
  tags                         = local.tags
}

# RDS

resource "random_password" "artifactory_db_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "artifactory_db_secret" {
  name                    = local.artifactory_db_secret_name
  description             = "Artifactory DB authentication token"
  recovery_window_in_days = var.recovery_window
  kms_key_id              = module.artifactory_kms_key.kms_key_arn
}

module "artifactory_db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.5.4"
  tags    = local.tags

  identifier                     = var.artifactory_db_idenitfier_prefix
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
  instance_class       = var.artifactory_rds_instance_class

  db_name  = var.artifactory_db_name
  username = "artifactory"
  port     = "5432"

  # Restoring from a snapshot
  snapshot_identifier = var.artifactory_db_snapshot

  subnet_ids                  = module.vpc.database_subnets
  db_subnet_group_name        = module.vpc.database_subnet_group_name
  manage_master_user_password = false
  password                    = random_password.artifactory_db_password.result

  multi_az = false

  copy_tags_to_snapshot = true

  allow_major_version_upgrade = false
  auto_minor_version_upgrade  = false

  deletion_protection = true

  vpc_security_group_ids = [aws_security_group.artifactory_rds_sg.id]
}

resource "aws_security_group" "artifactory_rds_sg" {
  vpc_id = module.vpc.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "artifactory_rds_ingress" {
  security_group_id = aws_security_group.artifactory_rds_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 0
  to_port     = 5432
}
