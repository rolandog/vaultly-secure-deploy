terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket is passed by scripts/tf.sh because it embeds the account id
  backend "s3" {
    key          = "rg-vaultly/network/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Namespace = "rg"
      Project   = "rg-vaultly"
      Root      = "network"
      ManagedBy = "opentofu"
    }
  }
}
