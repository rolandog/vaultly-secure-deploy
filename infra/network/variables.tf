variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  description = "VPC name and cluster name used in subnet tags"
  type        = string
  default     = "rg-vaultly"

  validation {
    condition     = startswith(var.name, "rg-")
    error_message = "name must start with rg-"
  }
}

variable "vpc_cidr" {
  description = "Must be a /16: the subnet maths below assume it"
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16"
  }
}

variable "availability_zones" {
  description = "AZ names to use; pinned so a new AZ never changes the layout"
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  validation {
    condition     = length(var.availability_zones) >= 2 && length(var.availability_zones) <= 3
    error_message = "use 2 or 3 availability zones"
  }
}

variable "single_nat_gateway" {
  description = "One NAT for all AZs (cheaper; egress from other AZs depends on this one)"
  type        = bool
  default     = true
}
