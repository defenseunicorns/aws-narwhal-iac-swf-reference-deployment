locals {
  gitlab_db_secret_name            = join("-", compact([local.prefix, "gitlab-db-secret", local.suffix]))
  gitlab_kms_key_alias_name_prefix = join("-", compact([local.prefix, var.gitlab_kms_key_alias, local.suffix]))
  gitlab_dlm_role_name             = join("-", compact([local.prefix, "dlm-lifecycle-gitlab", local.suffix]))
}

module "gitlab_s3_bucket" {
  for_each = toset(var.gitlab_bucket_names)

  source = "git::https://github.com/terraform-aws-modules/terraform-aws-s3-bucket.git?ref=v4.1.0"

  bucket        = join("-", compact([local.prefix, each.key, local.suffix]))
  tags          = local.tags
  force_destroy = var.gitlab_s3_bucket_force_destroy

  versioning = {
    status = "Enabled"
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.gitlab_kms_key.kms_key_arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "gitlab_s3_bucket" {
  for_each = toset(var.gitlab_bucket_names)

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

module "gitlab_kms_key" {
  source = "github.com/defenseunicorns/terraform-aws-uds-kms?ref=v0.0.3"

  kms_key_alias_name_prefix = local.gitlab_kms_key_alias_name_prefix
  kms_key_deletion_window   = 7
  kms_key_description       = "GitLab Key"
}

module "gitlab_irsa_s3" {
  source = "./modules/irsa-s3"

  stage                = var.stage
  serviceaccount_names = var.gitlab_service_account_names
  policy_name          = "gitlab"
  prefix               = local.prefix
  suffix               = local.suffix
  k8s_namespace        = var.gitlab_namespace
  bucket_names         = var.gitlab_bucket_names
  kms_key_arn          = module.gitlab_kms_key.kms_key_arn
  oidc_provider_arn    = module.eks.oidc_provider_arn
}

module "gitlab_volume_snapshots" {
  source        = "./modules/volume-snapshot"
  dlm_role_name = local.gitlab_dlm_role_name

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
    NamespaceAndId = "gitlab-${lower(random_id.default.hex)}"
  }
  lifecycle_policy_description = "Policy for Gitlab volume snapshots"
  tags                         = local.tags
}

# RDS

resource "random_password" "gitlab_db_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "gitlab_db_secret" {
  name                    = local.gitlab_db_secret_name
  description             = "Gitlab DB authentication token"
  recovery_window_in_days = var.recovery_window
  kms_key_id              = module.gitlab_kms_key.kms_key_arn
}

module "gitlab_db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.1.1"
  tags    = local.tags

  identifier                     = var.gitlab_db_idenitfier_prefix
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
  instance_class       = var.gitlab_rds_instance_class

  db_name  = var.gitlab_db_name
  username = "gitlab"
  port     = "5432"

  # Restoring from a snapshot
  snapshot_identifier = var.gitlab_db_snapshot

  subnet_ids                  = module.vpc.database_subnets
  db_subnet_group_name        = module.vpc.database_subnet_group_name
  manage_master_user_password = false
  password                    = random_password.gitlab_db_password.result

  multi_az = false

  copy_tags_to_snapshot = true

  allow_major_version_upgrade = false
  auto_minor_version_upgrade  = false

  deletion_protection = true

  vpc_security_group_ids = [aws_security_group.gitlab_rds_sg.id]
}

# If we want to replicate backups to another region https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance_automated_backups_replication

resource "aws_security_group" "gitlab_rds_sg" {
  vpc_id = module.vpc.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "gitlab_rds_ingress" {
  security_group_id = aws_security_group.gitlab_rds_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 0
  to_port     = 5432
}


# Elasticache

resource "random_password" "gitlab_elasticache_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "gitlab_elasticache_secret" {
  name                    = join("-", compact([local.prefix, "elasticache-secret", local.suffix]))
  description             = "swf-${var.stage} Elasticache authentication token"
  recovery_window_in_days = var.recovery_window
  kms_key_id              = module.gitlab_kms_key.kms_key_arn
}

resource "aws_elasticache_replication_group" "gitlab_redis" {
  replication_group_id = join("-", compact([local.prefix, var.gitlab_elasticache_cluster_name, local.suffix]))
  description          = "Redis Replication Group for GitLab"

  subnet_group_name = aws_elasticache_subnet_group.gitlab_redis.name

  node_type            = "cache.r6g.large"
  engine_version       = "7.0"
  parameter_group_name = "default.redis7"
  auth_token           = random_password.gitlab_elasticache_password.result
  port                 = 6379

  num_cache_clusters = 2

  automatic_failover_enabled = true
  multi_az_enabled           = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  security_group_ids = [aws_security_group.gitlab_redis_sg.id]
}

resource "aws_elasticache_subnet_group" "gitlab_redis" {
  name       = join("-", compact([local.prefix, "gitlab-redis-cache-subnet", local.suffix]))
  subnet_ids = concat(module.vpc.public_subnets, module.vpc.private_subnets, module.vpc.database_subnets)
}

resource "aws_security_group" "gitlab_redis_sg" {
  vpc_id = module.vpc.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "gitlab_redis_ingress" {
  security_group_id = aws_security_group.gitlab_redis_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 0
  to_port     = 6379
}
