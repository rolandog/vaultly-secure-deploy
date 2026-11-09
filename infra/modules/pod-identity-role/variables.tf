variable "name" {
  description = "IAM role name (must start with rg-)"
  type        = string

  validation {
    condition     = startswith(var.name, "rg-")
    error_message = "role names must start with rg-"
  }
}

variable "namespace" {
  description = "Kubernetes namespace allowed to assume the role"
  type        = string
}

variable "service_account" {
  description = "Kubernetes ServiceAccount allowed to assume the role"
  type        = string
}

variable "managed_policy_arns" {
  description = "AWS managed policy ARNs to attach"
  type        = list(string)
  default     = []
}

