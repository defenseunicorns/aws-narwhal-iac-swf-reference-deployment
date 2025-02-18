resource "random_id" "default" {
  byte_length = 2
}

data "terraform_remote_state" "swf_state" {
  backend = "s3"
  config = {
    bucket = var.bucket
    key    = var.key
    region = var.region
  }
}

locals {
  # If 'var.prefix' is explicitly null, allow it to be empty
  # If 'var.prefix' is an empty string, generate a prefix
  # If 'var.prefix' is neither null nor an empty string, assign the value of 'var.prefix' itself
  prefix = var.prefix == null ? "" : (
    var.prefix == "" ? join("-", compact([var.namespace, var.stage, var.name])) :
    var.prefix
  )

  # If 'var.suffix' is null, assign an empty string
  # If 'var.suffix' is an empty string, assign a randomly generated hexadecimal value
  # If 'var.suffix' is neither null nor an empty string, assign the value of 'var.suffix' itself
  suffix = var.suffix == null ? "" : (
    var.suffix == "" ? lower(random_id.default.hex) :
    var.suffix
  )
  transit_gateway_name = join("-", compact([local.prefix, var.tgw_name, local.suffix]))

  tags = merge(
    var.tags,
    {
      RootTFModule = replace(basename(path.cwd), "_", "-"), # tag names based on the directory name
      GithubRepo   = "github.com/defenseunicorns/narwhal-delivery-iac-swf-reference-deployment"
    }
  )
}

####################################################################################################
# create a blank transit gateway
# this is to demonstate a pattern that is common in certain environments where a transit gateway may already exist in the environment that is peer'd to somewhere else
####################################################################################################

module "transit_gateway" {
  source = "git::https://github.com/defenseunicorns/terraform-aws-transit-gateway.git?ref=v0.0.4"

  create_transit_gateway                         = true
  create_transit_gateway_route_table             = false
  create_transit_gateway_vpc_attachment          = false
  create_transit_gateway_route_table_association = false
  create_transit_gateway_propagation             = false
  transit_gateway_name                           = local.transit_gateway_name

  tags = local.tags
}


####################################################################################################
# reference an existing transit gateway and wire existing VPC resources to it
# associating the VPC to the transit gateway is a common pattern in environments where the VPCs and transit gateway already exist and are being configured to use the transit gateway
####################################################################################################

locals {
  vpc_and_tgw_rtb_configuration = {
    (var.stage) = {
      vpc_name                          = data.terraform_remote_state.swf_state.outputs.vpc.name                    # VPC to attach to the transit gateway, used for naming the transit gateway vpc association resources
      vpc_id                            = data.terraform_remote_state.swf_state.outputs.vpc.vpc_id                  # VPC to attach to the transit gateway
      vpc_cidr                          = data.terraform_remote_state.swf_state.outputs.vpc.vpc_cidr_block          # CIDR block of the VPC
      subnet_ids                        = data.terraform_remote_state.swf_state.outputs.vpc.private_subnets         # VPC subnets to attach to the transit gateway
      subnet_route_table_ids            = data.terraform_remote_state.swf_state.outputs.vpc.private_route_table_ids # VPC subnet route tables to create routes to the transit gateway inside of
      route_to                          = []                                                                        # can use this to reference other vpc_cidr from keys in this same map
      route_to_cidr_blocks              = ["8.8.8.8/32", "8.8.4.4/32"]                                              # static routes to add to the VPC subnet route tables that will point to the transit gateway
      transit_gateway_vpc_attachment_id = null                                                                      # null assumes that it will be creating a new vpc attachment in the module call itself
      static_routes = [
        {
          blackhole                           = false
          destination_cidr_block              = data.terraform_remote_state.swf_state.outputs.vpc.vpc_cidr_block
          route_transit_gateway_attachment_id = null # null means it will default to THIS VPC's attachment id
        },
        # {
        #   blackhole                           = false
        #   destination_cidr_block              = "0.0.0.0/0"
        #   route_transit_gateway_attachment_id = "tgw-attach-0dc32c85d99cfe7c1" # an ID here means it will use the specified attachment id to send traffic out of, this would be where you'd put a peering connection's attachment id
        # },
      ]
    }
  }
  transit_gateway_route_table_name = join("-", compact([local.transit_gateway_name, data.terraform_remote_state.swf_state.outputs.vpc.name, "rtb"]))
}

# dat

module "transit_gateway_attachment" {
  source = "git::https://github.com/defenseunicorns/terraform-aws-transit-gateway.git?ref=v0.0.4"

  create_transit_gateway                         = false
  use_existing_transit_gateway                   = true
  existing_transit_gateway_id                    = module.transit_gateway.transit_gateway_id
  create_transit_gateway_route_table             = true
  create_transit_gateway_vpc_attachment          = true
  create_transit_gateway_route_table_association = true
  create_transit_gateway_propagation             = false
  transit_gateway_name                           = local.transit_gateway_name
  transit_gateway_route_table_name               = local.transit_gateway_route_table_name
  route_keys_enabled                             = true

  config = local.vpc_and_tgw_rtb_configuration

  tags = local.tags
}
