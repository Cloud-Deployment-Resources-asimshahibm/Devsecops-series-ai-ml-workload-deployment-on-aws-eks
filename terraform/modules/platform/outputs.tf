output "argocd_namespace" {
  value = helm_release.argocd.namespace
}

output "lbc_role_arn" {
  value = module.lbc_irsa.iam_role_arn
}

output "postgres_service" {
  value = "platform-postgres.platform-system.svc.cluster.local"
}
