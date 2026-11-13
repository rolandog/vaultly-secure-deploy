output "role_arn" {
  value = aws_iam_role.gha_readonly.arn
}

output "role_name" {
  value = aws_iam_role.gha_readonly.name
}

output "trusted_subs" {
  value = local.subs
}
