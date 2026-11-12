output "app_fqdn" {
  description = "Public name of the vaultly endpoint"
  value       = local.app_fqdn
}

output "alb_dns_name" {
  description = "DNS name of the ALB the alias points to"
  value       = data.aws_lb.app.dns_name
}
