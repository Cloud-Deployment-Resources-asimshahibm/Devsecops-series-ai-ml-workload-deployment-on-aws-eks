################################################################################
# One customer-managed KMS key per environment.
# Used for: EKS secrets envelope encryption, S3, EFS, EBS (Karpenter nodes),
# RDS storage + Performance Insights, Secrets Manager, CloudWatch logs.
################################################################################

variable "name" { type = string }

variable "deletion_window_in_days" {
  type    = number
  default = 30
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "key" {
  # checkov:skip=CKV_AWS_109: KMS key policy — "*" resource means "this key"; account root admin is the AWS-recommended default
  # checkov:skip=CKV_AWS_111: same (key policy, not an identity policy)
  # checkov:skip=CKV_AWS_356: same
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # EBS volumes launched by Auto Scaling / Karpenter on behalf of the account
  statement {
    sid = "AllowEC2AutoscalingUse"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }
  }

  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.name} platform key"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.key.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-platform"
  target_key_id = aws_kms_key.this.key_id
}

output "key_arn" { value = aws_kms_key.this.arn }
output "key_id" { value = aws_kms_key.this.key_id }
output "alias" { value = aws_kms_alias.this.name }
