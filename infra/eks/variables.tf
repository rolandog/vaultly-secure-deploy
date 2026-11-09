variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "cluster_name" {
  type    = string
  default = "rg-vaultly"

  validation {
    condition     = startswith(var.cluster_name, "rg-")
    error_message = "cluster_name must start with rg-"
  }
}

variable "kubernetes_version" {
  description = "Check AWS standard-support dates before changing"
  type        = string
  default     = "1.36"

  validation {
    condition     = contains(["1.35", "1.36", "1.37"], var.kubernetes_version)
    error_message = "use 1.35, 1.36 or 1.37 (1.34 leaves standard support on 2026-12-02)"
  }
}

variable "admin_cidr" {
  description = "Your public IP as a /32; the only source allowed to reach the API endpoint"
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && endswith(var.admin_cidr, "/32")
    error_message = "admin_cidr must be a single address, a.b.c.d/32"
  }
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "ami_type" {
  type    = string
  default = "AL2023_ARM_64_STANDARD"
}

variable "node_count" {
  description = "3 so three OpenBao replicas can spread across nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 3 && var.node_count <= 4
    error_message = "node_count must be 3 or 4"
  }
}

variable "log_retention_days" {
  type    = number
  default = 7
}
