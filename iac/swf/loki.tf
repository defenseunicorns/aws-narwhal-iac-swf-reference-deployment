locals {
  loki_kms_key_alias_name_prefix = join("-", compact([local.prefix, var.loki_kms_key_alias, local.suffix]))
  loki_dlm_role_name             = join("-", compact([local.prefix, "dlm-lifecycle-loki", local.suffix]))
}

module "loki_s3_bucket" {
  for_each = toset(var.loki_bucket_names)

  source = "git::https://github.com/terraform-aws-modules/terraform-aws-s3-bucket.git?ref=v4.6.0"

  bucket        = join("-", compact([local.prefix, each.key, local.suffix]))
  tags          = local.tags
  force_destroy = var.loki_s3_bucket_force_destroy

  versioning = {
    status = "Enabled"
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.loki_kms_key.kms_key_arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki_s3_bucket" {
  for_each = toset(var.loki_bucket_names)

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

module "loki_kms_key" {
  source = "github.com/defenseunicorns/terraform-aws-uds-kms?ref=v0.0.6"

  kms_key_alias_name_prefix = local.loki_kms_key_alias_name_prefix
  kms_key_deletion_window   = 7
  kms_key_description       = "Loki Key"
}

module "loki_irsa_s3" {
  source = "./modules/irsa-s3"

  stage                = var.stage
  serviceaccount_names = var.loki_service_account_names
  policy_name          = "loki"
  prefix               = local.prefix
  suffix               = local.suffix
  k8s_namespace        = var.loki_namespace
  bucket_names         = var.loki_bucket_names
  kms_key_arn          = module.loki_kms_key.kms_key_arn
  oidc_provider_arn    = module.eks.oidc_provider_arn
}

module "loki_volume_snapshots" {
  source        = "./modules/volume-snapshot"
  dlm_role_name = local.loki_dlm_role_name

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
    NamespaceAndId = "loki-${lower(random_id.default.hex)}"
  }
  lifecycle_policy_description = "Policy for Loki volume snapshots"
  tags                         = local.tags
}
