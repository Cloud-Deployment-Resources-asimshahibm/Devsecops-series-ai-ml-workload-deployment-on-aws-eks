variable "region" {
  description = "AWS region for shared resources (state bucket, ECR)."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project prefix used in every resource name."
  type        = string
  default     = "aiml"
}

variable "github_org" {
  description = "GitHub organization or user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without the org)."
  type        = string
}

variable "ecr_repositories" {
  description = "Container repositories shared by all environments (build once, promote everywhere)."
  type        = list(string)
  default     = ["ml-inference", "ml-training", "ml-ray"]
}

variable "environments" {
  description = "Environments whose GitHub Environment may assume the apply role."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "activate_cost_allocation_tags" {
  description = "Activate Project/Environment/nodepool cost allocation tags (set true ~24h after first apply of an env)."
  type        = bool
  default     = false
}

variable "billing_alert_emails" {
  description = "Recipients of Cost Anomaly Detection alerts (and default for budgets)."
  type        = list(string)
  default     = []
}

variable "anomaly_threshold_usd" {
  type    = number
  default = 50
}

variable "security_services" {
  description = "Account-level security services. Set a flag to false if it is already managed centrally (Organizations / Control Tower)."
  type = object({
    guardduty       = bool
    securityhub     = bool
    inspector       = bool
    config          = bool
    cloudtrail      = bool
    access_analyzer = bool
    macie           = bool
  })
  default = {
    guardduty       = true
    securityhub     = true
    inspector       = true
    config          = true
    cloudtrail      = true
    access_analyzer = true
    macie           = true
  }
}
