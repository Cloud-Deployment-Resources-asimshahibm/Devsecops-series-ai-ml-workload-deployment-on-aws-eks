################################################################################
# Account-level security baseline (run once per account/region from
# terraform/global). Every service can be toggled off when it is already
# managed centrally (e.g. by AWS Organizations / Control Tower).
#
#  Detect      GuardDuty (S3, EKS audit logs, Runtime Monitoring w/ managed EKS add-on, EBS malware)
#  Posture     Security Hub (AWS FSBP + CIS AWS Foundations v3.0) · AWS Config + managed rules
#  Vulns       Amazon Inspector v2 (ECR + EC2) · ECR registry ENHANCED continuous scanning
#  Audit       CloudTrail (multi-region, KMS, log-file validation, S3 + CloudWatch Logs)
#  IAM         IAM Access Analyzer (external access findings)
#  Data        Amazon Macie (classification jobs are created per environment)
################################################################################

variable "project" { type = string }

variable "enable" {
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

variable "log_retention_days" {
  type    = number
  default = 365
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.name
  part    = data.aws_partition.current.partition
  name    = "${var.project}-security"
}

# ------------------------------------------------------------------ KMS for security logs
data "aws_iam_policy_document" "logs_key" {
  # checkov:skip=CKV_AWS_109: KMS key policy — "*" resource means "this key"; account root admin is the AWS-recommended default
  # checkov:skip=CKV_AWS_111: same (key policy, not an identity policy)
  # checkov:skip=CKV_AWS_356: same
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.part}:iam::${local.account}:root"]
    }
  }
  statement {
    sid       = "CloudTrailEncrypt"
    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.part}:cloudtrail:*:${local.account}:trail/*"]
    }
  }
  statement {
    sid       = "ServicesUseKey"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com", "config.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "${local.name} audit & security logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.logs_key.json
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

# ------------------------------------------------------------------ audit log bucket
resource "aws_s3_bucket" "audit" {
  bucket = "${local.name}-audit-logs-${local.account}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    id     = "archive-then-expire"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = var.log_retention_days * 7 # keep 7 years for regulated workloads
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "audit_bucket" {

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
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
  statement {
    sid       = "AWSLogDeliveryAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com", "config.amazonaws.com"]
    }
  }
  statement {
    sid       = "AWSLogDeliveryWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/AWSLogs/${local.account}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com", "config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json
}

# ------------------------------------------------------------------ CloudTrail
resource "aws_cloudwatch_log_group" "trail" {
  count             = var.enable.cloudtrail ? 1 : 0
  name              = "/aws/cloudtrail/${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

data "aws_iam_policy_document" "trail_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "trail_logs" {
  count              = var.enable.cloudtrail ? 1 : 0
  name               = "${local.name}-cloudtrail-logs"
  assume_role_policy = data.aws_iam_policy_document.trail_assume.json
}

resource "aws_iam_role_policy" "trail_logs" {
  count = var.enable.cloudtrail ? 1 : 0
  name  = "write-logs"
  role  = aws_iam_role.trail_logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.trail[0].arn}:*"
    }]
  })
}

resource "aws_cloudtrail" "this" {
  # checkov:skip=CKV_AWS_252: SNS delivery notifications not needed — alerts come from Security Hub / GuardDuty
  # checkov:skip=CKV2_AWS_10: integrated with CloudWatch Logs (cloud_watch_logs_group_arn) — graph check cannot resolve count index
  count                         = var.enable.cloudtrail ? 1 : 0
  name                          = "${local.name}-trail"
  s3_bucket_name                = aws_s3_bucket.audit.id
  kms_key_id                    = aws_kms_key.logs.arn
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.trail[0].arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.trail_logs[0].arn

  # S3 data events on the ML data buckets (who read / wrote models & datasets)
  advanced_event_selector {
    name = "ML data + model registry object access"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = ["arn:${local.part}:s3:::${var.project}-dev-ml-data-${local.account}/", "arn:${local.part}:s3:::${var.project}-prod-ml-data-${local.account}/"]
    }
  }

  advanced_event_selector {
    name = "Management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  depends_on = [aws_s3_bucket_policy.audit]
}

# ------------------------------------------------------------------ GuardDuty
resource "aws_guardduty_detector" "this" {
  # checkov:skip=CKV2_AWS_3: single-account reference; enable org-wide via delegated admin in multi-account setups
  count                        = var.enable.guardduty ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector_feature" "simple" {
  for_each    = var.enable.guardduty ? toset(["S3_DATA_EVENTS", "EKS_AUDIT_LOGS", "EBS_MALWARE_PROTECTION"]) : toset([])
  detector_id = aws_guardduty_detector.this[0].id
  name        = each.key
  status      = "ENABLED"
}

# Runtime Monitoring: GuardDuty manages its security agent as an EKS add-on
resource "aws_guardduty_detector_feature" "runtime" {
  count       = var.enable.guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.this[0].id
  name        = "RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}

# ------------------------------------------------------------------ Security Hub
resource "aws_securityhub_account" "this" {
  count                    = var.enable.securityhub ? 1 : 0
  enable_default_standards = false
  auto_enable_controls     = true
}

resource "aws_securityhub_standards_subscription" "this" {
  for_each = var.enable.securityhub ? toset([
    "arn:${local.part}:securityhub:${local.region}::standards/aws-foundational-security-best-practices/v/1.0.0",
    "arn:${local.part}:securityhub:${local.region}::standards/cis-aws-foundations-benchmark/v/3.0.0",
  ]) : toset([])
  standards_arn = each.key
  depends_on    = [aws_securityhub_account.this]
}

# Route GuardDuty / Inspector / Macie / Config / Access Analyzer findings into Security Hub
resource "aws_securityhub_product_subscription" "inspector" {
  count       = var.enable.securityhub && var.enable.inspector ? 1 : 0
  product_arn = "arn:${local.part}:securityhub:${local.region}::product/aws/inspector"
  depends_on  = [aws_securityhub_account.this]
}

# ------------------------------------------------------------------ Inspector v2 + ECR enhanced scanning
resource "aws_inspector2_enabler" "this" {
  count          = var.enable.inspector ? 1 : 0
  account_ids    = [local.account]
  resource_types = ["ECR", "EC2"]
}

resource "aws_ecr_registry_scanning_configuration" "this" {
  count     = var.enable.inspector ? 1 : 0
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "${var.project}/*"
      filter_type = "WILDCARD"
    }
  }

  depends_on = [aws_inspector2_enabler.this]
}

# ------------------------------------------------------------------ AWS Config
data "aws_iam_policy_document" "config_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  count              = var.enable.config ? 1 : 0
  name               = "${local.name}-aws-config"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}

resource "aws_iam_role_policy_attachment" "config" {
  count      = var.enable.config ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${local.part}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "this" {
  count    = var.enable.config ? 1 : 0
  name     = "${local.name}-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  count          = var.enable.config ? 1 : 0
  name           = "${local.name}-delivery"
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_kms_key_arn = aws_kms_key.logs.arn
  depends_on     = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.audit]
}

resource "aws_config_configuration_recorder_status" "this" {
  # checkov:skip=CKV2_AWS_45: recorder uses all_supported = true (graph check cannot resolve count index)
  count      = var.enable.config ? 1 : 0
  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

resource "aws_config_config_rule" "managed" {
  for_each = var.enable.config ? toset([
    "EKS_SECRETS_ENCRYPTED",
    "EKS_CLUSTER_LOGGING_ENABLED",
    "EKS_ENDPOINT_NO_PUBLIC_ACCESS",
    "ECR_PRIVATE_IMAGE_SCANNING_ENABLED",
    "ENCRYPTED_VOLUMES",
    "RDS_STORAGE_ENCRYPTED",
    "S3_BUCKET_SSL_REQUESTS_ONLY",
    "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED",
    "CLOUD_TRAIL_ENABLED",
    "IAM_ROOT_ACCESS_KEY_CHECK",
    "MFA_ENABLED_FOR_IAM_CONSOLE_ACCESS",
    "VPC_FLOW_LOGS_ENABLED",
  ]) : toset([])

  name = lower(replace(each.key, "_", "-"))
  source {
    owner             = "AWS"
    source_identifier = each.key
  }
  depends_on = [aws_config_configuration_recorder_status.this]
}

# ------------------------------------------------------------------ IAM Access Analyzer
resource "aws_accessanalyzer_analyzer" "this" {
  count         = var.enable.access_analyzer ? 1 : 0
  analyzer_name = "${local.name}-account-analyzer"
  type          = "ACCOUNT"
}

# ------------------------------------------------------------------ Macie
resource "aws_macie2_account" "this" {
  count                        = var.enable.macie ? 1 : 0
  finding_publishing_frequency = "SIX_HOURS"
  status                       = "ENABLED"
}

output "logs_kms_key_arn" { value = aws_kms_key.logs.arn }
output "audit_bucket" { value = aws_s3_bucket.audit.bucket }
output "guardduty_detector_id" { value = try(aws_guardduty_detector.this[0].id, null) }
output "macie_enabled" { value = var.enable.macie }
