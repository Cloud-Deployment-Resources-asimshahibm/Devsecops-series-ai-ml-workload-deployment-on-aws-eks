project         = "aiml"
environment     = "prod"
region          = "us-east-1"
gitops_repo_url = "https://github.com/Cloud-Deployment-Resources-asimshahibm/DevOps-Series-AI-ML-Workload-deployment-on-AWS-EKS.git"
gitops_revision = "main"

vpc_cidr           = "10.20.0.0/16"
single_nat_gateway = false # one NAT per AZ

kubernetes_version = "1.33"

# Your admin role (scripts/configure.sh fills this from `aws sts get-caller-identity`)
cluster_admin_principal_arns = ["__ADMIN_ROLE_ARN__"]

# Replace with your corporate egress / VPN CIDRs before applying prod
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

system_node_group = {
  instance_types = ["m6i.large"]
  min_size       = 3
  max_size       = 4
  desired_size   = 3
}

rds = {
  instance_class        = "db.r7g.large"
  multi_az              = true
  deletion_protection   = true
  backup_retention_days = 14
}

argocd_ha = true

# Billing guardrails (AWS Budgets). Add recipients, e.g. ["platform-team@example.com"]
budgets = {
  monthly_total_usd   = 6000
  monthly_compute_usd = 4500
  alert_emails        = []
}
