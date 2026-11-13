variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "oidc_provider_arn" { type = string }
variable "environment" { type = string }
variable "efs_id" { type = string }
variable "kms_key_arn" { type = string }
variable "postgres_address" { type = string }

variable "karpenter" {
  description = "Outputs of the karpenter sub-module."
  type = object({
    queue_name = string
  })
}

variable "gitops_repo_url" {
  description = "HTTPS URL of this repository; Argo CD syncs from it."
  type        = string
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "bootstrap_gitops" {
  description = "Create the Argo CD root (app-of-apps) Application."
  type        = bool
  default     = true
}

variable "argocd_ha" {
  description = "Run Argo CD in HA mode (recommended for prod)."
  type        = bool
  default     = false
}

# Pinned chart versions = reproducible platform. Bump them via PR, never `latest`.
variable "chart_versions" {
  type = object({
    aws_load_balancer_controller = string
    metrics_server               = string
    karpenter                    = string
    argo_cd                      = string
    argocd_apps                  = string
  })
  default = {
    aws_load_balancer_controller = "1.11.0"
    metrics_server               = "3.12.2"
    karpenter                    = "1.1.1"
    argo_cd                      = "7.7.10"
    argocd_apps                  = "2.0.2"
  }
}
