data "aws_caller_identity" "current" {}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "tf-state-${data.aws_caller_identity.current.account_id}-eu-central-1"
    key    = "rg-vaultly/network/terraform.tfstate"
    region = var.region
  }
}

locals {
  net = data.terraform_remote_state.network.outputs

  # Graviton families have a "g" after the generation digit: t4g, m6g, c7gd, ...
  is_arm = can(regex("^[a-z]+[0-9]+g[a-z]*\\.", var.instance_type))
}

# Preconditions fail the plan by themselves. Do not make module.eks depend on
# this resource: a module-level depends_on defers the module's data sources
# to apply time and breaks count in the EKS node group submodule.
resource "terraform_data" "guard" {
  lifecycle {
    precondition {
      condition     = local.is_arm == (var.ami_type == "AL2023_ARM_64_STANDARD")
      error_message = "instance_type ${var.instance_type} and ami_type ${var.ami_type} differ in architecture"
    }

    precondition {
      condition     = length(local.net.private_subnet_ids) >= 3
      error_message = "apply infra/network first (need 3 private subnets)"
    }
  }
}

module "ebs_csi_role" {
  source = "../modules/pod-identity-role"

  name                = "${var.cluster_name}-ebs-csi"
  namespace           = "kube-system"
  service_account     = "ebs-csi-controller-sa"
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
}

module "eks" {
  #checkov:skip=CKV_TF_1:registry module pinned by ~> constraint; resolved version recorded in docs/evidence/02-module-versions.txt
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = local.net.vpc_id
  subnet_ids = local.net.private_subnet_ids

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = [var.admin_cidr]

  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = false

  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  addons = {
    eks-pod-identity-agent = {
      before_compute = true
    }

    vpc-cni = {
      before_compute       = true
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }

    kube-proxy = {}
    coredns    = {}

    aws-ebs-csi-driver = {
      pod_identity_association = [
        {
          role_arn        = module.ebs_csi_role.role_arn
          service_account = "ebs-csi-controller-sa"
        }
      ]
    }
  }

  eks_managed_node_groups = {
    main = {
      ami_type       = var.ami_type
      instance_types = [var.instance_type]

      min_size     = var.node_count
      max_size     = var.node_count
      desired_size = var.node_count

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"

          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

}
