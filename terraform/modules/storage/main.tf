################################################################################
# Data plane storage
#   S3  ml-data       datasets/, models/ (model registry), tuning/
#   S3  wf-artifacts  Argo Workflows artifact repository
#   S3  loki          Loki chunks + index (TSDB)
#   EFS               RWX volumes: JupyterHub homes, shared datasets, Ray scratch
################################################################################

variable "name" { type = string }
variable "kms_key_arn" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "allowed_security_group_ids" {
  description = "Static keys -> SG ids (map so for_each works when ids are unknown at plan time)."
  type        = map(string)
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete non-empty buckets (dev only)."
  type        = bool
  default     = false
}

data "aws_caller_identity" "current" {}

locals {
  buckets = {
    data      = "${var.name}-ml-data-${data.aws_caller_identity.current.account_id}"
    artifacts = "${var.name}-wf-artifacts-${data.aws_caller_identity.current.account_id}"
    loki      = "${var.name}-loki-${data.aws_caller_identity.current.account_id}"
  }
}

# ------------------------------------------------------------------ S3
resource "aws_s3_bucket" "this" {
  for_each      = local.buckets
  bucket        = each.value
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = { for k, v in local.buckets : k => v if k != "loki" } # Loki manages its own retention
  bucket   = aws_s3_bucket.this[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  rule {
    id     = "housekeeping"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-workflow-artifacts"
    status = each.key == "artifacts" ? "Enabled" : "Disabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.this
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]
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

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  policy   = data.aws_iam_policy_document.tls_only[each.key].json
}

# ------------------------------------------------------------------ EFS
resource "aws_security_group" "efs" {
  name        = "${var.name}-efs"
  description = "NFS from EKS nodes"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  for_each                     = var.allowed_security_group_ids
  security_group_id            = aws_security_group.efs.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  description                  = "NFS from cluster nodes"
}

resource "aws_efs_file_system" "this" {
  creation_token   = "${var.name}-efs"
  encrypted        = true
  kms_key_id       = var.kms_key_arn
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = { Name = "${var.name}-efs" }
}

resource "aws_efs_backup_policy" "this" {
  file_system_id = aws_efs_file_system.this.id
  backup_policy {
    status = "ENABLED"
  }
}

resource "aws_efs_mount_target" "this" {
  count           = length(var.subnet_ids) # ids unknown at plan time, count is known
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

output "bucket_names" { value = { for k, b in aws_s3_bucket.this : k => b.bucket } }
output "bucket_arns" { value = { for k, b in aws_s3_bucket.this : k => b.arn } }
output "efs_id" { value = aws_efs_file_system.this.id }
