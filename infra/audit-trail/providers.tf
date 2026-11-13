terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket is passed with -backend-config because it embeds the account id
  backend "s3" {
    key          = "rg-vaultly/audit-trail/terraform.tfstate"
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
      ManagedBy = "opentofu"
    }
  }
}
