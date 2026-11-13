output "account_id" {
  value = local.account_id
}

output "state_bucket" {
  description = "Use this as `bucket` in every backend.hcl."
  value       = aws_s3_bucket.tfstate.bucket
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "github_oidc_provider_arn" {
  value = module.github_oidc.oidc_provider_arn
}

output "gha_role_arns" {
  description = "Paste these into GitHub repository variables (see docs/RUNBOOK.md, Phase 2)."
  value = {
    AWS_ROLE_TF_PLAN  = module.github_oidc.terraform_plan_role_arn
    AWS_ROLE_TF_APPLY = module.github_oidc.terraform_apply_role_arn
    AWS_ROLE_CI       = module.github_oidc.ci_role_arn
  }
}
