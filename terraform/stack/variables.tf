variable "project" {
  type    = string
  default = "aiml"
}

variable "environment" {
  description = "dev | prod"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "gitops_repo_url" {
  description = "HTTPS clone URL of this repo, used by Argo CD."
  type        = string
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

# ----------------------------- network -----------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "true = 1 NAT (cheap, dev). false = 1 NAT per AZ (HA, prod)."
  type        = bool
  default     = true
}

variable "interface_endpoints" {
  description = "Interface VPC endpoints (~$7/month/AZ each). S3 gateway endpoint is always created."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "sts", "logs", "secretsmanager"]
}

# ----------------------------- cluster -----------------------------
variable "kubernetes_version" {
  type    = string
  default = "1.33"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Lock this to your office/VPN egress IPs."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_principal_arns" {
  description = "IAM role ARNs (not assumed-role session ARNs) granted cluster-admin, e.g. your SSO admin role."
  type        = list(string)
  default     = []
}

variable "system_node_group" {
  description = "Managed node group for controllers (Karpenter, CoreDNS, Argo CD, LBC)."
  type = object({
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
  })
  default = {
    instance_types = ["m6i.large"]
    min_size       = 2
    max_size       = 4
    desired_size   = 2
  }
}

# ----------------------------- database -----------------------------
variable "rds" {
  type = object({
    instance_class        = string
    multi_az              = bool
    deletion_protection   = bool
    backup_retention_days = number
  })
  default = {
    instance_class        = "db.t4g.medium"
    multi_az              = false
    deletion_protection   = false
    backup_retention_days = 7
  }
}

# ----------------------------- gitops -----------------------------
variable "argocd_ha" {
  type    = bool
  default = false
}

variable "bootstrap_gitops" {
  type    = bool
  default = true
}

# ----------------------------- billing -----------------------------
variable "budgets" {
  description = "Monthly AWS Budgets for this environment (USD). Alerts at 80%/100% actual and 100% forecast."
  type = object({
    monthly_total_usd   = number
    monthly_compute_usd = number
    alert_emails        = list(string)
  })
  default = {
    monthly_total_usd   = 800
    monthly_compute_usd = 500
    alert_emails        = []
  }
}
