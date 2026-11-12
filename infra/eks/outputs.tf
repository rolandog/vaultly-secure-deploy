output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "lbc_role_arn" {
  description = "Pod Identity role of the AWS Load Balancer Controller"
  value       = module.lbc_role.role_arn
}
