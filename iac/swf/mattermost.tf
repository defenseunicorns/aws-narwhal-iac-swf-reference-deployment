locals {
  mattermost_db_secret_name            = join("-", compact([local.prefix, "mattermost-db-secret", local.suffix]))
  mattermost_kms_key_alias_name_prefix = join("-", compact([local.prefix, var.mattermost_kms_key_alias, local.suffix]))
}

module "mattermost_s3_bucket" {
  for_each = toset(var.mattermost_bucket_names)

  source = "git::https://github.com/terraform-aws-modules/terraform-aws-s3-bucket.git?ref=v4.6.0"

  bucket        = join("-", compact([local.prefix, each.key, local.suffix]))
  force_destroy = var.mattermost_s3_bucket_force_destroy
  tags          = local.tags

  versioning = {
    status = "Enabled"
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.mattermost_kms_key.kms_key_arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "mattermost_s3_bucket" {
  for_each = toset(var.mattermost_bucket_names)

  bucket = join("-", compact([local.prefix, each.key, local.suffix]))

  rule {
    id = join("-", compact([local.prefix, each.key, "version-retention", local.suffix]))

    filter {}

    noncurrent_version_expiration {
      newer_noncurrent_versions = 5
      noncurrent_days           = 90
    }

    noncurrent_version_transition {
      newer_noncurrent_versions = 2
      storage_class             = "GLACIER_IR"
    }

    status = "Enabled"
  }
}

module "mattermost_kms_key" {
  source = "github.com/defenseunicorns/terraform-aws-uds-kms?ref=v0.0.6"

  kms_key_alias_name_prefix = local.mattermost_kms_key_alias_name_prefix
  kms_key_deletion_window   = 7
  kms_key_description       = "Mattermost Key"
}

module "mattermost_irsa_s3" {
  source = "./modules/irsa-s3"

  stage                = var.stage
  serviceaccount_names = var.mattermost_service_account_names
  policy_name          = "mattermost"
  prefix               = local.prefix
  suffix               = local.suffix
  k8s_namespace        = var.mattermost_namespace
  bucket_names         = var.mattermost_bucket_names
  kms_key_arn          = module.mattermost_kms_key.kms_key_arn
  oidc_provider_arn    = module.eks.oidc_provider_arn
}

# RDS

resource "random_password" "mattermost_db_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "mattermost_db_secret" {
  name                    = local.mattermost_db_secret_name
  description             = "Mattermost DB authentication token"
  recovery_window_in_days = var.recovery_window
  kms_key_id              = module.mattermost_kms_key.kms_key_arn
}

module "mattermost_db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.10.0"
  tags    = local.tags

  identifier                     = var.mattermost_db_idenitfier_prefix
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
  instance_class       = var.mattermost_rds_instance_class

  db_name  = var.mattermost_db_name
  username = "mattermost"
  port     = "5432"

  # Restoring from a snapshot
  snapshot_identifier = var.mattermost_db_snapshot

  subnet_ids                  = module.vpc.database_subnets
  db_subnet_group_name        = module.vpc.database_subnet_group_name
  manage_master_user_password = false
  password                    = random_password.mattermost_db_password.result

  multi_az = false

  copy_tags_to_snapshot = true

  allow_major_version_upgrade = false
  auto_minor_version_upgrade  = false

  deletion_protection = var.rds_deletion_protection

  vpc_security_group_ids = [aws_security_group.mattermost_rds_sg.id]
}

resource "aws_security_group" "mattermost_rds_sg" {
  vpc_id = module.vpc.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "mattermost_rds_ingress" {
  security_group_id = aws_security_group.mattermost_rds_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 0
  to_port     = 5432
}
