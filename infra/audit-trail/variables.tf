variable "region" {
  description = "Region of the trail home and the Athena table"
  type        = string
  default     = "eu-central-1"
}

variable "trail_name" {
  description = "Name of the CloudTrail trail"
  type        = string
  default     = "rg-vaultly-audit"

  validation {
    condition     = startswith(var.trail_name, "rg-vaultly-")
    error_message = "trail_name must start with rg-vaultly-"
  }
}

variable "log_retention_days" {
  description = "Days before trail logs and Athena results expire"
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 1 && var.log_retention_days <= 365
    error_message = "log_retention_days must be between 1 and 365"
  }
}

variable "manage_guardduty" {
  description = "Create a GuardDuty detector; keep false when one already exists (one per account and region)"
  type        = bool
  default     = false
}

variable "create_trail" {
  description = "Create the trail; false while the 5-trails-per-region quota is full (shared account)"
  type        = bool
  default     = false
}
