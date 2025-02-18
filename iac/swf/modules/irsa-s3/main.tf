
data "aws_partition" "current" {}

resource "random_id" "default" {
  byte_length = 2
}


locals {
  tags = merge(
    var.tags,
    {
      RootTFModule = replace(basename(path.cwd), "_", "-") # tag names based on the directory name
      Env          = var.stage
    }
  )
  s3_bucket_polcy_name = join("-", compact([var.prefix, var.policy_name, "s3-access-policy", var.suffix]))
  bucket_names         = length(var.bucket_names) > 0 ? [for bucket_name in var.bucket_names : join("-", compact([var.prefix, bucket_name, var.suffix]))] : []
}

data "aws_iam_policy_document" "s3_bucket_default" {
  statement {
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads"
    ]

    resources = [
      for bucket_name in local.bucket_names :
      "arn:${data.aws_partition.current.partition}:s3:::${bucket_name}"
    ]
  }

  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload"
    ]

    resources = [
      for bucket_name in local.bucket_names :
      "arn:${data.aws_partition.current.partition}:s3:::${bucket_name}/*"
    ]
  }

  statement {
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt"
    ]

    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_policy" "s3_bucket_policy" {
  name        = local.s3_bucket_polcy_name
  path        = "/"
  description = "IRSA policy to access buckets."
  policy      = coalesce(var.irsa_iam_policy, data.aws_iam_policy_document.s3_bucket_default.json)
  tags        = local.tags
}

module "irsa_role" {
  for_each = toset(var.serviceaccount_names)

  source = "git::https://github.com/terraform-aws-modules/terraform-aws-iam.git//modules/iam-role-for-service-accounts-eks?ref=v5.52.2"

  role_name = join("-", compact([var.prefix, each.value, "s3-role", var.suffix]))

  role_policy_arns = {
    policy = aws_iam_policy.s3_bucket_policy.arn
  }

  oidc_providers = {
    one = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.k8s_namespace}:${each.value}"]
    }
  }
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "s3_policy_attach" {
  for_each = toset(var.serviceaccount_names)

  role       = join("-", compact([var.prefix, each.value, "s3-role", var.suffix]))
  policy_arn = aws_iam_policy.s3_bucket_policy.arn

  depends_on = [module.irsa_role]
}
