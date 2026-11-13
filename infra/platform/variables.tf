variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "cluster_name" {
  type    = string
  default = "rg-vaultly"
}

variable "openbao_namespace" {
  type    = string
  default = "openbao"
}

variable "openbao_service_account" {
  type    = string
  default = "openbao"
}

variable "zone_name" {
  type        = string
  description = "Existing public Route 53 zone owned by the rg-dns state; looked up, never created"
  default     = "ih.rolan.dog"

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.rolan\\.dog$", var.zone_name))
    error_message = "zone_name must look like <label>.rolan.dog"
  }
}

variable "app_hostname_label" {
  type        = string
  description = "Record label of the public vaultly endpoint inside the zone"
  default     = "rg-vaultly"

  validation {
    condition     = can(regex("^rg-[a-z0-9-]+$", var.app_hostname_label))
    error_message = "app_hostname_label must start with rg-"
  }
}
