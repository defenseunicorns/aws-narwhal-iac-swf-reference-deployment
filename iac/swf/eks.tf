locals {
  cluster_security_group_additional_rules = merge(
    { ingress_bastion_to_cluster = local.ingress_bastion_to_cluster },
  )

  uds_swf_ng_name = join("-", compact([local.prefix, var.uds_swf_ng_name, local.suffix]))
  gitaly_ng_name  = join("-", compact([local.prefix, var.gitaly_ng_name, local.suffix]))

  # self managed node groups settings
  self_managed_node_group_defaults = {
    iam_role_permissions_boundary          = var.iam_role_permissions_boundary
    instance_type                          = null # conflicts with instance_requirements settings
    update_launch_template_default_version = true

    use_mixed_instances_policy = true

    instance_requirements = {
      allowed_instance_types = ["m6i.4xlarge", "m5a.4xlarge"] #this should be adjusted to the appropriate instance family if reserved instances are being utilized
      memory_mib = {
        min = 64000
      }
      vcpu_count = {
        min = 16
      }
    }

    placement = {
      tenancy = var.eks_worker_tenancy
    }

    pre_bootstrap_userdata = <<-EOT
        yum install -y amazon-ssm-agent
        systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
      EOT

    post_userdata = <<-EOT
        echo "Bootstrap successfully completed! You can further apply config or install to run after bootstrap if needed"
      EOT

    # bootstrap_extra_args used only when you pass custom_ami_id. Allows you to change the Container Runtime for Nodes
    # e.g., bootstrap_extra_args="--use-max-pods false --container-runtime containerd"
    bootstrap_extra_args = "--use-max-pods false"

    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore      = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
      AmazonElasticFileSystemFullAccess = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonElasticFileSystemFullAccess"
    }

    # enable discovery of autoscaling groups by cluster-autoscaler
    autoscaling_group_tags = merge(
      {
        "k8s.io/cluster-autoscaler/enabled" : true,
        "k8s.io/cluster-autoscaler/${local.cluster_name}" : "owned"
    })

    metadata_options = {
      #https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template#metadata-options
      http_endpoint               = "enabled"
      http_put_response_hop_limit = 2
      http_tokens                 = "optional" # set to "enabled" to enforce IMDSv2, default for upstream terraform-aws-eks module
    }

    tags = {
      subnet_type                            = "private",
      cluster                                = local.cluster_name
      "aws-node-termination-handler/managed" = true # only need this if NTH is enabled. This is due to aws blueprints using this resource and causing the tags to flap on every apply https://github.com/aws-ia/terraform-aws-eks-blueprints-addons/blob/257677adeed1be54326637cf919cf24df6ad7c06/main.tf#L1554-L1564
    }
  }

  uds_swf_self_mg_node_group = {
    uds_ng = {
      name          = local.uds_swf_ng_name
      ami_type      = "BOTTLEROCKET_x86_64"
      ami_id        = data.aws_ami.eks_default_bottlerocket.id
      instance_type = null # conflicts with instance_requirements settings
      subnet_ids    = module.vpc.private_subnets
      min_size      = 3
      max_size      = 5
      desired_size  = 3
      key_name      = module.self_managed_node_group_keypair.key_pair_name

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 100
            volume_type = "gp3"
          }
        }
        xvdb = {
          device_name = "/dev/xvdb"
          ebs = {
            volume_size = 100
            volume_type = "gp3"
            #need to add and create EBS key
          }
        }
      }

      bootstrap_extra_args = <<-EOT
        # The admin host container provides SSH access and runs with "superpowers".
        # It is disabled by default.
        [settings.host-containers.admin]
        enabled = true

        # The control host container provides out-of-band access via SSM.
        # It is enabled by default, and can be disabled if you do not expect to use SSM.
        # This could leave you with no way to access the API and change settings on an existing node!
        [settings.host-containers.control]
        enabled = true

        # extra args added
        # [settings.kernel]
        # lockdown = "integrity"

        #[settings.kubernetes.node-labels]
        #label1 = "da-bb-nodes"
      EOT

    }
  }

  keycloak_self_mg_node_group = {
    keycloak_ng_sso = {
      ami_type      = "BOTTLEROCKET_x86_64"
      ami_id        = data.aws_ami.eks_default_bottlerocket.id
      instance_type = null # conflicts with instance_requirements settings
      min_size      = 2
      max_size      = 2
      desired_size  = 2
      key_name      = var.keycloak_enabled ? module.key_pair[0].key_pair_name : null

      bootstrap_extra_args = <<-EOT
        # The admin host container provides SSH access and runs with "superpowers".
        # It is disabled by default, but can be disabled explicitly.
        [settings.host-containers.admin]
        enabled = false

        # The control host container provides out-of-band access via SSM.
        # It is enabled by default, and can be disabled if you do not expect to use SSM.
        # This could leave you with no way to access the API and change settings on an existing node!
        [settings.host-containers.control]
        enabled = true

        # extra args added
        [settings.kernel]
        lockdown = "integrity"

        [settings.kubernetes.node-labels]
        label1 = "sso"
        label2 = "bb-core"

        [settings.kubernetes.node-taints]
        dedicated = "experimental:PreferNoSchedule"
        special = "true:NoSchedule"
      EOT
    }
  }

  gitaly_self_mg_node_group = {
    gitaly_ng = {
      name          = local.gitaly_ng_name
      ami_type      = "BOTTLEROCKET_x86_64"
      ami_id        = data.aws_ami.eks_default_bottlerocket.id
      instance_type = null # conflicts with instance_requirements settings
      min_size      = 1
      max_size      = 1
      desired_size  = 1
      subnet_ids    = [module.vpc.private_subnets[2]] # Constrain to a single subnet which corresponds to a single AZ
      key_name      = module.self_managed_node_group_keypair.key_pair_name

      instance_requirements = {
        allowed_instance_types = ["r6i.4xlarge", "r5.4xlarge"] #this should be adjusted to the appropriate instance family if reserved instances are being utilized
        memory_mib = {
          min = 127000
        }
        vcpu_count = {
          min = 15
        }
      }

      bootstrap_extra_args = <<-EOT
        # The admin host container provides SSH access and runs with "superpowers".
        # It is disabled by default, but can be disabled explicitly.
        [settings.host-containers.admin]
        enabled = true

        # The control host container provides out-of-band access via SSM.
        # It is enabled by default, and can be disabled if you do not expect to use SSM.
        # This could leave you with no way to access the API and change settings on an existing node!
        [settings.host-containers.control]
        enabled = true

        # extra args added
        #[settings.kernel]
        #lockdown = "integrity"

        [settings.kubernetes.node-labels]
        app = "gitaly"

        [settings.kubernetes.node-taints]
        dedicated = "gitaly:NoSchedule"
      EOT
    }
  }

  self_managed_node_groups = merge(
    local.uds_swf_self_mg_node_group,
    local.gitaly_self_mg_node_group,
    var.keycloak_enabled ? local.keycloak_self_mg_node_group : {}
  )

  vpc_cni_addon_irsa_extra_config = {
    "vpc-cni" = merge(
      var.cluster_addons["vpc-cni"],
      {
        service_account_role_arn = module.vpc_cni_ipv4_irsa_role.iam_role_arn
      }
    )
  }

  cluster_addons = merge(
    var.cluster_addons,
    local.vpc_cni_addon_irsa_extra_config
  )
}

module "ssm_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.0"

  create = var.create_ssm_parameters

  description = "KMS key for SecureString SSM parameters"

  key_administrators = [
    data.aws_iam_session_context.current.issuer_arn
  ]

  computed_aliases = {
    ssm = {
      name = "${local.kms_key_alias_name_prefix}-ssm"
    }
  }

  key_statements = [
    {
      sid    = "SSM service access"
      effect = "Allow"
      principals = [
        {
          type        = "Service"
          identifiers = ["ssm.amazonaws.com"]
        }
      ]
      actions = [
        "kms:Decrypt",
        "kms:Encrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]
      resources = ["*"]
    }
  ]

  tags = local.tags
}

locals {
  ssm_parameter_kms_key_arn = var.create_ssm_parameters ? module.ssm_kms_key.key_arn : ""

  # If the `enable_admin_roles_prefix_or_suffix` variable is set to true, it will generate a new list by concatenating the `local.prefix`, `role`, and `local.suffix` with a hyphen separator.
  admin_roles = var.enable_admin_roles_prefix_or_suffix ? [for role in var.admin_roles : join("-", compact([local.prefix, role, local.suffix]))] : var.admin_roles


  admin_user_access_entries = {
    for user in var.admin_users :
    user => {
      principal_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:user/${user}"
      type          = "STANDARD"
      policy_associations = {
        admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  admin_role_access_entries = {
    for role in local.admin_roles :
    role => {
      principal_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${role}"
      type          = "STANDARD"
      policy_associations = {
        admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  bastion_role_access_entry = {
    bastion = {
      principal_arn = module.bastion.bastion_role_arn
      type          = "STANDARD"
      policy_associations = {
        admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  access_entries = merge(
    local.admin_user_access_entries,
    local.admin_role_access_entries,
    local.bastion_role_access_entry,
    var.access_entries
  )

  # blueprints addons IAM role naming
  cluster_autoscaler_iam_role_name             = join("-", compact([local.prefix, "cluster-autoscaler", local.suffix]))
  cluster_autoscaler_iam_policy_name           = join("-", compact([local.prefix, "cluster-autoscaler-policy", local.suffix]))
  aws_node_termination_handler_iam_role_name   = join("-", compact([local.prefix, "aws-node-termination-handler", local.suffix]))
  aws_node_termination_handler_iam_policy_name = join("-", compact([local.prefix, "aws-node-termination-handler-policy", local.suffix]))
  aws_load_balancer_controller_iam_role_name   = join("-", compact([local.prefix, "aws-load-balancer-controller", local.suffix]))
  aws_load_balancer_controller_iam_policy_name = join("-", compact([local.prefix, "aws-load-balancer-controller-policy", local.suffix]))

  # naming of roles and policies. name_prefix makes the the resources flap, conflicts with helm inputs
  cluster_autoscaler = merge(
    var.cluster_autoscaler,
    {
      role_name_use_prefix   = false
      policy_name_use_prefix = false
      role_name              = local.cluster_autoscaler_iam_role_name
      policy_name            = local.cluster_autoscaler_iam_policy_name
    }
  )

  aws_node_termination_handler = merge(
    var.aws_node_termination_handler,
    {
      role_name_use_prefix   = false
      policy_name_use_prefix = false
      role_name              = local.aws_node_termination_handler_iam_role_name
      policy_name            = local.aws_node_termination_handler_iam_policy_name
    }
  )

  aws_load_balancer_controller = merge(
    var.aws_load_balancer_controller,
    {
      role_name_use_prefix   = false
      policy_name_use_prefix = false
      role_name              = local.aws_load_balancer_controller_iam_role_name
      policy_name            = local.aws_load_balancer_controller_iam_policy_name
    }
  )

}

module "eks" {
  source = "git::https://github.com/defenseunicorns/terraform-aws-eks.git?ref=v0.0.26"

  name                                    = local.cluster_name
  aws_region                              = var.region
  azs                                     = module.vpc.azs
  vpc_id                                  = module.vpc.vpc_id
  private_subnet_ids                      = module.vpc.private_subnets
  control_plane_subnet_ids                = module.vpc.private_subnets
  iam_role_permissions_boundary           = var.iam_role_permissions_boundary
  cluster_security_group_additional_rules = local.cluster_security_group_additional_rules
  cluster_endpoint_public_access          = var.cluster_endpoint_public_access
  cluster_endpoint_private_access         = true
  vpc_cni_custom_subnet                   = module.vpc.intra_subnets
  aws_admin_usernames                     = var.aws_admin_usernames
  cluster_version                         = var.cluster_version
  dataplane_wait_duration                 = var.dataplane_wait_duration

  ######################## EKS Authentication ###################################
  access_entries                           = local.access_entries
  authentication_mode                      = var.authentication_mode
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  ######################## Self Managed Node Group ###################################
  self_managed_node_group_defaults = local.self_managed_node_group_defaults
  self_managed_node_groups         = local.self_managed_node_groups

  tags = local.tags

  #---------------------------------------------------------------
  #"native" EKS Add-Ons
  #---------------------------------------------------------------
  cluster_addons = local.cluster_addons

  #---------------------------------------------------------------
  # EKS Blueprints - blueprints curated helm charts
  #---------------------------------------------------------------
  create_kubernetes_resources = var.create_kubernetes_resources
  create_ssm_parameters       = var.create_ssm_parameters
  ssm_parameter_kms_key_arn   = local.ssm_parameter_kms_key_arn

  # AWS EKS EBS CSI Driver
  enable_amazon_eks_aws_ebs_csi_driver = var.enable_amazon_eks_aws_ebs_csi_driver
  enable_gp3_default_storage_class     = var.enable_gp3_default_storage_class
  ebs_storageclass_reclaim_policy      = var.ebs_storageclass_reclaim_policy

  # AWS EKS EFS CSI Driver
  enable_amazon_eks_aws_efs_csi_driver = var.enable_amazon_eks_aws_efs_csi_driver
  efs_vpc_cidr_blocks                  = module.vpc.private_subnets_cidr_blocks
  efs_storageclass_reclaim_policy      = var.efs_storageclass_reclaim_policy

  # AWS EKS node termination handler
  enable_aws_node_termination_handler = var.enable_aws_node_termination_handler
  aws_node_termination_handler        = local.aws_node_termination_handler

  # k8s Metrics Server
  enable_metrics_server = var.enable_metrics_server
  metrics_server        = var.metrics_server

  # k8s Cluster Autoscaler
  enable_cluster_autoscaler = var.enable_cluster_autoscaler
  cluster_autoscaler        = local.cluster_autoscaler

  # AWS Load Balancer Controller
  enable_aws_load_balancer_controller = var.enable_aws_load_balancer_controller
  aws_load_balancer_controller        = local.aws_load_balancer_controller

  # k8s Secrets Store CSI Driver
  enable_secrets_store_csi_driver = var.enable_secrets_store_csi_driver
  secrets_store_csi_driver        = var.secrets_store_csi_driver

  # External Secrets
  enable_external_secrets               = var.enable_external_secrets
  external_secrets                      = var.external_secrets
  external_secrets_ssm_parameter_arns   = var.external_secrets_ssm_parameter_arns
  external_secrets_secrets_manager_arns = var.external_secrets_secrets_manager_arns
  external_secrets_kms_key_arns         = var.external_secrets_kms_key_arns
}

#---------------------------------------------------------------
#Keycloak Self Managed Node Group Dependencies
#---------------------------------------------------------------

module "key_pair" {
  source  = "terraform-aws-modules/key-pair/aws"
  version = "~> 2.0"

  count = var.keycloak_enabled ? 1 : 0

  key_name_prefix    = local.cluster_name
  create_private_key = true

  tags = local.tags
}

module "ebs_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.0"

  count = var.keycloak_enabled ? 1 : 0

  description = "Customer managed key to encrypt EKS managed node group volumes"

  # Policy
  key_administrators = [
    data.aws_iam_session_context.current.issuer_arn
  ]

  key_service_roles_for_autoscaling = [
    # required for the ASG to manage encrypted volumes for nodes
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
    # required for the cluster / persistentvolume-controller to create encrypted PVCs
    module.eks.cluster_iam_role_arn,
  ]

  # Aliases
  aliases                 = ["eks/keycloak_ng_sso/ebs"]
  aliases_use_name_prefix = true

  tags = local.tags
}

######################################################
# vpc-cni irsa role
######################################################
module "vpc_cni_ipv4_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name_prefix      = "${module.eks.cluster_name}-vpc-cni-"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  # extra policy to attach to the role
  role_policy_arns = {
    vpc_cni_logging = aws_iam_policy.vpc_cni_logging.arn
  }

  tags = local.tags
}

resource "aws_iam_policy" "vpc_cni_logging" {
  name        = join("-", compact([local.prefix, "vpc-cni-logging", local.suffix]))
  description = "Additional test policy"

  policy = jsonencode(
    {
      Version = "2012-10-17"
      Statement = [
        {
          Sid    = "CloudWatchLogging"
          Effect = "Allow"
          Action = [
            "logs:DescribeLogGroups",
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = "*"
        }
      ]
    }
  )

  tags = local.tags
}

######################################################
# EKS Self Managed Node Group Dependencies
######################################################
module "self_managed_node_group_keypair" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-key-pair?ref=v2.0.3"

  key_name_prefix    = "${local.cluster_name}-uds-swf-"
  create_private_key = true

  tags = local.tags
}

module "self_managed_node_group_secret_key_secrets_manager_secret" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-secrets-manager.git?ref=v1.3.1"

  name                    = module.self_managed_node_group_keypair.key_pair_name
  description             = "Secret key for the uds-swf self managed node group keypair"
  recovery_window_in_days = 7

  block_public_policy = true

  ignore_secret_changes = true
  secret_string         = module.self_managed_node_group_keypair.private_key_openssh

  tags = local.tags
}
