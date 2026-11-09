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
