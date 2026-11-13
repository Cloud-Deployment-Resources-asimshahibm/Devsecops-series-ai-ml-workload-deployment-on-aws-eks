################################################################################
# Day-0 platform installed by Terraform — only what must exist BEFORE GitOps:
#   storage classes, Postgres service alias, AWS LB Controller, metrics-server,
#   Karpenter (node provisioning), Argo CD + the root app-of-apps.
# Everything else (JupyterHub, Argo Workflows, KubeRay, Prometheus, Grafana,
# Loki, ELK, GPU operator, ML apps) is delivered by Argo CD from Git.
################################################################################

# ------------------------------------------------------------------------------
# Storage classes
# ------------------------------------------------------------------------------
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = var.kms_key_arn
    fsType    = "ext4"
    # cost allocation tags on every dynamically provisioned EBS volume
    tagSpecification_1 = "Project=${local.project}"
    tagSpecification_2 = "Environment=${var.environment}"
    tagSpecification_3 = "ManagedBy=ebs-csi"
  }
}

# RWX storage: each PVC gets its own EFS access point (uid/gid 1000 = jovyan/ray)
resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = "efs-sc"
  }
  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"
  parameters = {
    provisioningMode      = "efs-ap"
    fileSystemId          = var.efs_id
    directoryPerms        = "700"
    uid                   = "1000"
    gid                   = "100"
    basePath              = "/dynamic"
    subPathPattern        = "$${.PVC.namespace}/$${.PVC.name}"
    ensureUniqueDirectory = "true"
  }
}

# ------------------------------------------------------------------------------
# Stable in-cluster DNS name for RDS so Git never contains the RDS endpoint:
#   platform-postgres.platform-system.svc.cluster.local -> <rds>.rds.amazonaws.com
# ------------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "platform_system" {
  metadata {
    name   = "platform-system"
    labels = { "app.kubernetes.io/part-of" = "ml-platform" }
  }
}

resource "kubernetes_service_v1" "postgres" {
  metadata {
    name      = "platform-postgres"
    namespace = kubernetes_namespace_v1.platform_system.metadata[0].name
  }
  spec {
    type          = "ExternalName"
    external_name = var.postgres_address
    port {
      port = 5432
    }
  }
}

# ------------------------------------------------------------------------------
# IRSA for the AWS Load Balancer Controller
# ------------------------------------------------------------------------------
module "lbc_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                              = "${var.cluster_name}-aws-lbc"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_load_balancer_controller
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    clusterName  = var.cluster_name
    region       = var.region
    vpcId        = var.vpc_id
    replicaCount = 2
    # cost allocation tags on every ALB/NLB/target group the controller creates
    defaultTags = {
      Project     = local.project
      Environment = var.environment
      ManagedBy   = "aws-load-balancer-controller"
    }
    serviceAccount = {
      create      = true
      name        = "aws-load-balancer-controller"
      annotations = { "eks.amazonaws.com/role-arn" = module.lbc_irsa.iam_role_arn }
    }
    nodeSelector = { workload = "system" }
  })]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_versions.metrics_server
  namespace  = "kube-system"

  values = [yamlencode({
    replicas     = 2
    nodeSelector = { workload = "system" }
  })]
}

# ------------------------------------------------------------------------------
# Karpenter controller (runs on the system managed node group).
# NodePools / EC2NodeClasses are GitOps-managed: charts/karpenter-nodepools
# ------------------------------------------------------------------------------
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.chart_versions.karpenter
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    replicas     = 2
    nodeSelector = { workload = "system" }
    serviceAccount = {
      name = "karpenter" # Pod Identity association created by the karpenter sub-module
    }
    settings = {
      clusterName       = var.cluster_name
      clusterEndpoint   = var.cluster_endpoint
      interruptionQueue = var.karpenter.queue_name # Spot interruption / rebalance events via SQS
    }
    controller = {
      resources = {
        requests = { cpu = "500m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
    }
    serviceMonitor = { enabled = false } # flipped on by GitOps once Prometheus CRDs exist
  })]
}

# ------------------------------------------------------------------------------
# Argo CD
# ------------------------------------------------------------------------------
locals {
  project = split("-", var.cluster_name)[0]

  # Argo CD >= 1.8 does not assess Application health by default; without this
  # sync-waves in the app-of-apps would not wait for child apps to be Healthy.
  app_health_lua = <<-EOT
    hs = {}
    hs.status = "Progressing"
    hs.message = ""
    if obj.status ~= nil then
      if obj.status.health ~= nil then
        hs.status = obj.status.health.status
        if obj.status.health.message ~= nil then
          hs.message = obj.status.health.message
        end
      end
    end
    return hs
  EOT
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_versions.argo_cd
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [yamlencode({
    global = {
      nodeSelector = { workload = "system" }
    }
    configs = {
      params = {
        "server.insecure" = true # TLS terminates at the ALB / port-forward
      }
      cm = {
        "timeout.reconciliation"                                 = "120s"
        "resource.customizations.health.argoproj.io_Application" = local.app_health_lua
        "statusbadge.enabled"                                    = "true"
      }
    }
    redis-ha = { enabled = var.argocd_ha }
    controller = {
      replicas = var.argocd_ha ? 2 : 1
      metrics  = { enabled = true }
    }
    server = {
      replicas = var.argocd_ha ? 2 : 1
      metrics  = { enabled = true }
    }
    repoServer = {
      replicas = var.argocd_ha ? 2 : 1
      metrics  = { enabled = true }
    }
    applicationSet = { replicas = var.argocd_ha ? 2 : 1 }
  })]

  depends_on = [helm_release.aws_lbc, helm_release.karpenter]
}

# ------------------------------------------------------------------------------
# GitOps bootstrap: ONE root Application (Helm chart argocd/app-of-apps rendered
# with values-<env>.yaml) -> every other component comes from Git.
# ------------------------------------------------------------------------------
resource "helm_release" "argocd_root_app" {
  count = var.bootstrap_gitops ? 1 : 0

  name       = "argocd-root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.chart_versions.argocd_apps
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      "root-${var.environment}" = {
        namespace  = "argocd"
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "argocd/app-of-apps"
          helm = {
            valueFiles = ["values.yaml", "values-${var.environment}.yaml"]
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true"]
        }
      }
    }
  })]

  depends_on = [helm_release.argocd]
}
