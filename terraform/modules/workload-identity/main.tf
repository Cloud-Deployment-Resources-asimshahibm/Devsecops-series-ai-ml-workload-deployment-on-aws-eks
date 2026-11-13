################################################################################
# IRSA roles for every workload that talks to AWS. One role per job-to-be-done,
# each bound to explicit namespace:serviceaccount pairs (least privilege).
#
#  role               service accounts                                   access
#  -----------------  -------------------------------------------------  ------------------------------
#  ml-training        ml-training:ml-training, ray:ray-worker             data rw, artifacts rw
#  ml-inference       ml-serving:ml-inference                             data/models ro
#  jupyter-user       jupyterhub:jupyter-user                             data rw, artifacts ro
#  argo-workflows     argo:argo-workflows-server, argo:argo-workflow      artifacts rw
#  loki               monitoring:loki                                     loki bucket rw
#  grafana            monitoring:kube-prometheus-stack-grafana            CloudWatch read (billing, ALB, RDS)
#  image-verifier     kyverno:kyverno-admission-controller, trivy-system  ECR read (cosign signatures, image scans)
#  external-secrets   external-secrets:external-secrets                   secretsmanager <name>/* ro
################################################################################

variable "name" { type = string }
variable "oidc_provider_arn" { type = string }
variable "kms_key_arn" { type = string }
variable "bucket_arns" { type = map(string) } # keys: data, artifacts, loki

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  data      = var.bucket_arns["data"]
  artifacts = var.bucket_arns["artifacts"]
  loki      = var.bucket_arns["loki"]

  s3_ro = ["s3:GetObject", "s3:GetObjectVersion"]
  s3_rw = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject"]
  kms   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]

  roles = {
    ml-training = {
      sas = ["ml-training:ml-training", "ray:ray-worker"]
      statements = [
        { actions = ["s3:ListBucket", "s3:GetBucketLocation"], resources = [local.data, local.artifacts] },
        { actions = local.s3_rw, resources = ["${local.data}/*", "${local.artifacts}/*"] },
      ]
    }
    ml-inference = {
      sas = ["ml-serving:ml-inference"]
      statements = [
        { actions = ["s3:ListBucket"], resources = [local.data] },
        { actions = local.s3_ro, resources = ["${local.data}/models/*"] },
      ]
    }
    jupyter-user = {
      sas = ["jupyterhub:jupyter-user"]
      statements = [
        { actions = ["s3:ListBucket", "s3:GetBucketLocation"], resources = [local.data, local.artifacts] },
        { actions = local.s3_rw, resources = ["${local.data}/datasets/*", "${local.data}/scratch/*"] },
        { actions = local.s3_ro, resources = ["${local.data}/*", "${local.artifacts}/*"] },
      ]
    }
    argo-workflows = {
      sas = ["argo:argo-workflows-server", "argo:argo-workflow"]
      statements = [
        { actions = ["s3:ListBucket", "s3:GetBucketLocation"], resources = [local.artifacts] },
        { actions = local.s3_rw, resources = ["${local.artifacts}/*"] },
      ]
    }
    loki = {
      sas = ["monitoring:loki"]
      statements = [
        { actions = ["s3:ListBucket"], resources = [local.loki] },
        { actions = local.s3_rw, resources = ["${local.loki}/*"] },
      ]
    }
    grafana = {
      # CloudWatch datasource: AWS/Billing EstimatedCharges, ALB, RDS, EFS, NAT metrics
      sas = ["monitoring:kube-prometheus-stack-grafana"]
      statements = [
        {
          actions = [
            "cloudwatch:DescribeAlarmsForMetric", "cloudwatch:DescribeAlarmHistory", "cloudwatch:DescribeAlarms",
            "cloudwatch:ListMetrics", "cloudwatch:GetMetricData", "cloudwatch:GetInsightRuleReport",
            "ec2:DescribeTags", "ec2:DescribeInstances", "ec2:DescribeRegions", "tag:GetResources",
          ]
          resources = ["*"]
        },
      ]
    }
    # Kyverno verifies cosign signatures stored next to images in ECR;
    # Trivy Operator pulls image manifests/layers to scan running workloads.
    image-verifier = {
      sas = ["kyverno:kyverno-admission-controller", "trivy-system:trivy-operator"]
      statements = [
        { actions = ["ecr:GetAuthorizationToken"], resources = ["*"] },
        {
          actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "ecr:DescribeImages", "ecr:ListImages"]
          resources = ["arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/*"]
        },
      ]
    }
    external-secrets = {
      sas = ["external-secrets:external-secrets"]
      statements = [
        {
          actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:ListSecretVersionIds"]
          resources = ["arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.name}/*"]
        },
      ]
    }
  }
}

data "aws_iam_policy_document" "this" {
  for_each = local.roles

  dynamic "statement" {
    for_each = each.value.statements
    content {
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }

  statement {
    sid       = "KmsForEncryptedData"
    actions   = local.kms
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_policy" "this" {
  for_each = local.roles
  name     = "${var.name}-${each.key}"
  policy   = data.aws_iam_policy_document.this[each.key].json
}

module "irsa" {
  source   = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version  = "~> 5.48"
  for_each = local.roles

  role_name        = "${var.name}-${each.key}"
  role_policy_arns = { main = aws_iam_policy.this[each.key].arn }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = each.value.sas
    }
  }
}

output "role_arns" {
  value = { for k, m in module.irsa : k => m.iam_role_arn }
}
