variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "github_owner" {
  type    = string
  default = "rolandog"
}

variable "github_owner_id" {
  description = "numeric owner id, from the repo API (immutable subject format)"
  type        = number
  default     = 12400926
}

variable "github_repo" {
  type    = string
  default = "vaultly-secure-deploy"
}

variable "github_repo_id" {
  description = "numeric repo id, from the repo API (immutable subject format)"
  type        = number
  default     = 1454133213
}

variable "trusted_branches" {
  description = "branches whose workflow runs may assume the role; exact names only"
  type        = list(string)
  default     = ["develop", "main"]

  validation {
    condition     = length(var.trusted_branches) > 0 && !anytrue([for b in var.trusted_branches : strcontains(b, "*")])
    error_message = "trusted_branches must be non-empty and must not contain wildcards"
  }
}

variable "ci_secret_name" {
  description = "SecureString parameter the pipeline may read; created out of band so the value never enters state"
  type        = string
  default     = "/rg-vaultly/ci/demo-token"

  validation {
    condition     = startswith(var.ci_secret_name, "/rg-vaultly/ci/") && !strcontains(var.ci_secret_name, "*")
    error_message = "ci_secret_name must live under /rg-vaultly/ci/ and contain no wildcard"
  }
}
