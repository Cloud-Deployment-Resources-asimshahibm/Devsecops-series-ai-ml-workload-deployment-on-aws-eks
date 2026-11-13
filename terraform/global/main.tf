################################################################################
# GLOBAL / SHARED LAYER
# - Remote state bucket (S3 native locking, no DynamoDB needed on TF >= 1.10)
# - GitHub Actions OIDC provider + least-privilege roles
# - Shared ECR repositories (images are built once and promoted dev -> prod)
################################################################################

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "${var.project}-tfstate-${local.account_id}"
}

# ------------------------------------------------------------------------------
# Terraform remote state bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Customer-managed key for Terraform state (state contains generated passwords)
resource "aws_kms_key" "tfstate" {
  description             = "${var.project} Terraform state"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.tfstate_kms.json
}

# Key admin stays with the account (IAM decides who); use only through S3 in this account.
data "aws_iam_policy_document" "tfstate_kms" {
  # In a key policy "Resource: *" means "this key" only
  #checkov:skip=CKV_AWS_111:key policy - resource is the key itself
  #checkov:skip=CKV_AWS_356:key policy - resource is the key itself
  #checkov:skip=CKV_AWS_109:key policy - account root administration is the AWS-recommended default
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
  statement {
    sid       = "UseOnlyViaS3"
    effect    = "Deny"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:Encrypt", "kms:ReEncrypt*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 180
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json
}

# ------------------------------------------------------------------------------
# Shared ECR repositories
# ------------------------------------------------------------------------------
module "ecr" {
  source       = "../modules/ecr"
  project      = var.project
  repositories = var.ecr_repositories
}

# ------------------------------------------------------------------------------
# GitHub Actions OIDC federation + roles
# ------------------------------------------------------------------------------
module "github_oidc" {
  source = "../modules/github-oidc"

  project            = var.project
  github_org         = var.github_org
  github_repo        = var.github_repo
  environments       = var.environments
  state_bucket_arn   = aws_s3_bucket.tfstate.arn
  state_kms_key_arn  = aws_kms_key.tfstate.arn
  ecr_repository_arn = values(module.ecr.repository_arns)
}

# ------------------------------------------------------------------------------
# Billing: cost allocation tags + Cost Anomaly Detection (account-wide)
# ------------------------------------------------------------------------------
# Activate only after the tags appear in billing data (~24h after first tagged
# resource), otherwise the API rejects them. Then tag-filtered budgets and
# Cost Explorer "group by tag" work.
resource "aws_ce_cost_allocation_tag" "this" {
  for_each = var.activate_cost_allocation_tags ? toset(["Project", "Environment", "nodepool"]) : toset([])
  tag_key  = each.key
  status   = "Active"
}

resource "aws_ce_anomaly_monitor" "services" {
  name              = "${var.project}-service-spend"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "services" {
  count     = length(var.billing_alert_emails) > 0 ? 1 : 0
  name      = "${var.project}-anomaly-alerts"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  dynamic "subscriber" {
    for_each = var.billing_alert_emails
    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }

  # alert when an anomaly's impact is >= $X (absolute)
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }
}

# ------------------------------------------------------------------------------
# DevSecOps: account-level security baseline (detect · posture · audit · data)
# ------------------------------------------------------------------------------
module "security_baseline" {
  source  = "../modules/security-baseline"
  project = var.project
  enable  = var.security_services
}
