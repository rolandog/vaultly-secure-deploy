data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-name"
    values = var.availability_zones
  }

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.names) == length(var.availability_zones)
      error_message = "not all requested availability zones are available"
    }
  }
}

locals {
  # sorted: the existing subnets were laid out in alphabetical zone order
  azs              = sort(data.aws_availability_zones.available.names)
  az_count         = length(local.azs)
  public_subnets   = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 1)]
  database_subnets = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 100)]
}

module "vpc" {
  #checkov:skip=CKV_TF_1:registry module pinned by ~> constraint; resolved version recorded in docs/evidence/02-module-versions.txt
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  # the database tier is isolated: its own route table has no NAT route
  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  enable_dns_hostnames = true

  # default SG and NACL: adopt with no rules (locked down)
  manage_default_security_group = true
  manage_default_network_acl    = true
  manage_default_route_table    = true

  # only the load balancer lives in the public tier
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  enable_flow_log                                 = true
  flow_log_destination_type                       = "cloud-watch-logs"
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = 7
}
