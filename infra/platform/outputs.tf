output "kms_key_arn" {
  value = aws_kms_key.seal.arn
}

output "kms_key_id" {
  value = aws_kms_key.seal.key_id
}

output "kms_alias" {
  value = aws_kms_alias.seal.name
}

output "openbao_role_arn" {
  value = module.openbao_role.role_arn
}

output "app_fqdn" {
  description = "Public name of the vaultly endpoint"
  value       = local.app_fqdn
}

output "app_certificate_arn" {
  description = "Issued ACM certificate for the ALB listener (depends on validation)"
  value       = aws_acm_certificate_validation.app.certificate_arn
}
