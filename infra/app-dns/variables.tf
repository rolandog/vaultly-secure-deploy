variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "zone_name" {
  description = "Existing public Route 53 zone owned by the rg-dns state; looked up, never created (same value as infra/platform)"
  type        = string
  default     = "ih.rolan.dog"

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.rolan\\.dog$", var.zone_name))
    error_message = "zone_name must look like <label>.rolan.dog"
  }
}

variable "app_hostname_label" {
  description = "Record label of the public vaultly endpoint (same value as infra/platform)"
  type        = string
  default     = "rg-vaultly"

  validation {
    condition     = can(regex("^rg-[a-z0-9-]+$", var.app_hostname_label))
    error_message = "app_hostname_label must start with rg-"
  }
}

variable "alb_name" {
  description = "Name of the ALB the controller creates; must equal loadBalancerName in k8s/gateway/loadbalancerconfig.yaml"
  type        = string
  default     = "rg-vaultly-alb"

  validation {
    condition     = startswith(var.alb_name, "rg-")
    error_message = "alb_name must start with rg-"
  }
}
