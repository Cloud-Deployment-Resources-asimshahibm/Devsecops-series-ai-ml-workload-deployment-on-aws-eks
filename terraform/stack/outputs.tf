output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "kms_key_arn" {
  value = module.kms.key_arn
}

output "buckets" {
  value = module.storage.bucket_names
}

output "efs_id" {
  value = module.storage.efs_id
}

output "rds_address" {
  value = module.database.address
}

output "rds_secret_prefix" {
  value = module.database.secret_prefix
}

output "karpenter_node_role" {
  value = module.karpenter.node_iam_role_name
}

output "irsa_role_arns" {
  description = "Must match the serviceAccount annotations in the GitOps values (scripts/configure.sh renders them)."
  value       = module.workload_identity.role_arns
}

output "budgets" {
  value = module.cost_guardrails.budget_names
}

output "waf_web_acl_arn" {
  description = "Rendered into ingress annotations by scripts/render-security-outputs.sh"
  value       = module.waf.web_acl_arn
}
