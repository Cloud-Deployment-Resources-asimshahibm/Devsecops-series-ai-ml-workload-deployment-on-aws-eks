################################################################################
# ENVIRONMENT STACK (dev / prod)
#
#   KMS ─┬─> VPC (public / private / intra / database subnets, NAT, endpoints)
#        ├─> EKS (system MNG) + Karpenter (CPU + GPU NodePools via GitOps)
#        ├─> Storage: S3 (data, workflow artifacts, loki) + EFS (RWX)
#        ├─> RDS PostgreSQL (JupyterHub, Argo Workflows archive) + Secrets Manager
#        ├─> IRSA roles for every workload
#        └─> Day-0 platform (LBC, metrics-server, Karpenter, Argo CD root app)
################################################################################

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  azs        = slice(data.aws_availability_zones.available.names, 0, 3)
  account_id = data.aws_caller_identity.current.account_id

  # roles created by terraform/global
  ci_role       = "arn:aws:iam::${local.account_id}:role/${var.project}-gha-ci"
  tf_plan_role  = "arn:aws:iam::${local.account_id}:role/${var.project}-gha-tf-plan"
  tf_apply_role = "arn:aws:iam::${local.account_id}:role/${var.project}-gha-tf-apply"

  cluster_admins = distinct(concat(var.cluster_admin_principal_arns, [local.tf_apply_role]))

  # nodes from the managed node group use the cluster primary SG; Karpenter nodes use the node SG
  cluster_security_groups = {
    node    = module.eks.node_security_group_id
    primary = module.eks.cluster_primary_security_group_id
  }

  # Karpenter discovers subnets + security groups by this tag
  discovery_tag = { "karpenter.sh/discovery" = local.name }
}

# ------------------------------------------------------------------------------
# Encryption
# ------------------------------------------------------------------------------
module "kms" {
  source = "../modules/kms"
  name   = local.name
}

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # private /20 per AZ (pods, prefix delegation) | public: ALBs + NAT
  # intra: EKS control-plane ENIs | database: RDS, no internet route
  private_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets    = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]
  database_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 56)]

  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway
  enable_dns_hostnames   = true
  enable_dns_support     = true

  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = merge(local.discovery_tag, {
    "kubernetes.io/role/internal-elb" = 1
  })
}

# Private connectivity to AWS APIs: image pulls, STS (IRSA), logs and secrets
# never traverse the NAT gateway.
resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name}-vpce"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints" {
  description       = "HTTPS to interface endpoints from inside the VPC"
  security_group_id = aws_security_group.vpc_endpoints.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.16"

  vpc_id = module.vpc.vpc_id

  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
        tags            = { Name = "${local.name}-s3" }
      }
    },
    {
      for svc in var.interface_endpoints : svc => {
        service             = svc
        private_dns_enabled = true
        subnet_ids          = module.vpc.private_subnets
        security_group_ids  = [aws_security_group.vpc_endpoints.id]
        tags                = { Name = "${local.name}-${svc}" }
      }
    }
  )
}

# ------------------------------------------------------------------------------
# EKS
# ------------------------------------------------------------------------------
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true
  ebs_csi_kms_cmk_ids   = [module.kms.key_arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

module "efs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name             = "${local.name}-efs-csi"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa", "kube-system:efs-csi-node-sa"]
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  cluster_enabled_log_types            = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Envelope-encrypt Kubernetes Secrets with our CMK
  create_kms_key = false
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = module.kms.key_arn
  }

  enable_irsa = true

  # Explicit admins instead of "whoever ran the first apply": avoids access
  # entry churn when the same stack is applied by a human and by CI.
  enable_cluster_creator_admin_permissions = false

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # Karpenter nodes join with the node SG found via this tag
  node_security_group_tags = local.discovery_tag

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true, before_compute = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      configuration_values = jsonencode({
        env = { ENABLE_PREFIX_DELEGATION = "true", WARM_PREFIX_TARGET = "1" }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
    aws-efs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.efs_csi_irsa.iam_role_arn
    }
  }

  # Only the "system" group is managed by EKS. CPU and GPU capacity for ML
  # workloads is provisioned just-in-time by Karpenter.
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_node_group.instance_types
      min_size       = var.system_node_group.min_size
      max_size       = var.system_node_group.max_size
      desired_size   = var.system_node_group.desired_size
      labels         = { workload = "system" }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = module.kms.key_arn
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required" # IMDSv2 only
        http_put_response_hop_limit = 1          # pods use IRSA, never the node role
      }
    }
  }

  access_entries = merge(
    # Platform admins (your SSO/admin role, set by scripts/configure.sh) + CI apply role
    {
      for i, arn in local.cluster_admins : "admin-${i}" => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      # terraform plan on PRs: read everything (incl. Helm release secrets), change nothing
      terraform_plan = {
        principal_arn = local.tf_plan_role
        policy_associations = {
          view = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
      # GitHub Actions CI role -> k8s group bound (by charts/ml-pipelines) to a
      # Role that may only submit Argo Workflows in namespace ml-training.
      github_ci = {
        principal_arn     = local.ci_role
        kubernetes_groups = ["ci-workflow-submitters"]
      }
    }
  )
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.29"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true

  enable_pod_identity             = true
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${local.name}-karpenter-node" # referenced by EC2NodeClass in Git
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Karpenter launches nodes whose root volumes are encrypted with our CMK
  iam_policy_statements = [
    {
      sid       = "KmsForEncryptedNodeVolumes"
      actions   = ["kms:CreateGrant", "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKeyWithoutPlaintext", "kms:ReEncrypt*"]
      resources = [module.kms.key_arn]
    }
  ]
}

# ------------------------------------------------------------------------------
# Data plane: S3 + EFS, RDS, workload identities
# ------------------------------------------------------------------------------
module "storage" {
  source = "../modules/storage"

  name                       = local.name
  kms_key_arn                = module.kms.key_arn
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnets
  allowed_security_group_ids = local.cluster_security_groups
  force_destroy              = var.environment == "dev"
}

module "database" {
  source = "../modules/database"

  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  db_subnet_group_name       = module.vpc.database_subnet_group_name
  allowed_security_group_ids = local.cluster_security_groups
  kms_key_arn                = module.kms.key_arn
  instance_class             = var.rds.instance_class
  multi_az                   = var.rds.multi_az
  deletion_protection        = var.rds.deletion_protection
  backup_retention_days      = var.rds.backup_retention_days
}

module "workload_identity" {
  source = "../modules/workload-identity"

  name              = local.name
  oidc_provider_arn = module.eks.oidc_provider_arn
  kms_key_arn       = module.kms.key_arn
  bucket_arns       = module.storage.bucket_arns
}

# ------------------------------------------------------------------------------
# Day-0 platform
# ------------------------------------------------------------------------------
module "platform" {
  source = "../modules/platform"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  region            = var.region
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.oidc_provider_arn
  environment       = var.environment
  efs_id            = module.storage.efs_id
  kms_key_arn       = module.kms.key_arn
  postgres_address  = module.database.address
  karpenter         = { queue_name = module.karpenter.queue_name }
  gitops_repo_url   = var.gitops_repo_url
  gitops_revision   = var.gitops_revision
  bootstrap_gitops  = var.bootstrap_gitops
  argocd_ha         = var.argocd_ha

  depends_on = [module.eks, module.karpenter]
}

# ------------------------------------------------------------------------------
# Billing guardrails (AWS Budgets on the Environment tag)
# ------------------------------------------------------------------------------
module "cost_guardrails" {
  source = "../modules/cost-guardrails"

  name               = local.name
  environment        = var.environment
  monthly_budget_usd = var.budgets.monthly_total_usd
  compute_budget_usd = var.budgets.monthly_compute_usd
  alert_emails       = var.budgets.alert_emails
}

# ------------------------------------------------------------------------------
# DevSecOps: edge protection + sensitive-data discovery
# ------------------------------------------------------------------------------
module "waf" {
  source              = "../modules/waf"
  name                = local.name
  kms_key_arn         = module.kms.key_arn
  rate_limit_per_5min = var.waf.rate_limit_per_5min
}

# Weekly Macie scan of datasets / model registry for PII & credentials
resource "aws_macie2_classification_job" "ml_data" {
  count               = var.macie_scan_ml_data ? 1 : 0
  name                = "${local.name}-ml-data-weekly"
  job_type            = "SCHEDULED"
  sampling_percentage = var.environment == "prod" ? 100 : 25

  schedule_frequency {
    weekly_schedule = "SUNDAY"
  }

  s3_job_definition {
    bucket_definitions {
      account_id = local.account_id
      buckets    = [module.storage.bucket_names["data"]]
    }
  }
}
