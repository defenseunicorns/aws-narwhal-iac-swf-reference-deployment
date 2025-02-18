locals {
  azs              = [for az_name in slice(data.aws_availability_zones.available.names, 0, min(length(data.aws_availability_zones.available.names), var.num_azs)) : az_name]
  public_subnets   = [for k, v in module.subnet_addrs.network_cidr_blocks : v if strcontains(k, "public")]
  private_subnets  = [for k, v in module.subnet_addrs.network_cidr_blocks : v if strcontains(k, "private")]
  database_subnets = [for k, v in module.subnet_addrs.network_cidr_blocks : v if strcontains(k, "database")]
}

module "subnet_addrs" {
  source = "git::https://github.com/hashicorp/terraform-cidr-subnets?ref=v1.0.0"

  base_cidr_block = var.vpc_cidr
  networks        = var.vpc_subnets
}

module "vpc" {
  source = "git::https://github.com/defenseunicorns/terraform-aws-vpc.git?ref=v0.1.13"

  name                  = local.vpc_name
  vpc_cidr              = var.vpc_cidr
  secondary_cidr_blocks = var.secondary_cidr_blocks
  azs                   = local.azs
  public_subnets        = local.public_subnets
  private_subnets       = local.private_subnets
  database_subnets      = local.database_subnets
  intra_subnets         = [for k, v in module.vpc.azs : cidrsubnet(element(module.vpc.vpc_secondary_cidr_blocks, 0), 5, k)]
  enable_nat_gateway    = var.enable_nat_gateway
  single_nat_gateway    = var.single_nat_gateway

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  create_database_subnet_group = true

  instance_tenancy                  = "default"
  vpc_flow_log_permissions_boundary = var.iam_role_permissions_boundary

  tags = local.tags
}
