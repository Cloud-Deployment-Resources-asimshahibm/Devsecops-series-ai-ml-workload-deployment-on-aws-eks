################################################################################
# GitHub Actions -> AWS via OIDC (no long-lived access keys anywhere)
#
#  role                    | who can assume it                         | permissions
#  ------------------------|-------------------------------------------|------------------------------
#  <project>-gha-tf-plan   | pull_request events                       | ReadOnlyAccess + state bucket
#  <project>-gha-tf-apply  | GitHub Environments dev / prod only       | AdministratorAccess (*)
#  <project>-gha-ci        | main branch + environments                | ECR push, eks:DescribeCluster
#
# (*) Scope this down with a permissions boundary for real production accounts.
################################################################################

variable "project" { type = string }
variable "github_org" { type = string }
variable "github_repo" { type = string }
variable "environments" { type = list(string) }
variable "state_bucket_arn" { type = string }
variable "state_kms_key_arn" { type = string }
variable "ecr_repository_arn" { type = list(string) }

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  repo         = "${var.github_org}/${var.github_repo}"
  env_subjects = [for e in var.environments : "repo:${local.repo}:environment:${e}"]
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan  = ["repo:${local.repo}:pull_request", "repo:${local.repo}:ref:refs/heads/main"]
    apply = local.env_subjects
    ci    = concat(["repo:${local.repo}:ref:refs/heads/main"], local.env_subjects)
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

# ---------------- terraform plan (read-only) ----------------
resource "aws_iam_role" "tf_plan" {
  name               = "${var.project}-gha-tf-plan"
  assume_role_policy = data.aws_iam_policy_document.trust["plan"].json
}

resource "aws_iam_role_policy_attachment" "tf_plan_ro" {
  role       = aws_iam_role.tf_plan.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "state_rw" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/*"] # PutObject/DeleteObject needed for *.tflock files
  }
  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.state_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "tf_plan_state" {
  name   = "tfstate-access"
  role   = aws_iam_role.tf_plan.id
  policy = data.aws_iam_policy_document.state_rw.json
}

# ---------------- terraform apply (environment-gated) ----------------
resource "aws_iam_role" "tf_apply" {
  name                 = "${var.project}-gha-tf-apply"
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
  max_session_duration = 7200 # EKS create can take ~20 min, leave headroom
}

resource "aws_iam_role_policy_attachment" "tf_apply_admin" {
  role       = aws_iam_role.tf_apply.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

# ---------------- CI: build/push images, read cluster ----------------
resource "aws_iam_role" "ci" {
  name               = "${var.project}-gha-ci"
  assume_role_policy = data.aws_iam_policy_document.trust["ci"].json
}

data "aws_iam_policy_document" "ci" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
      "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arn
  }
  statement {
    sid       = "EksDescribe"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["arn:${data.aws_partition.current.partition}:eks:*:${data.aws_caller_identity.current.account_id}:cluster/${var.project}-*"]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "ci"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}

output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.github.arn }
output "terraform_plan_role_arn" { value = aws_iam_role.tf_plan.arn }
output "terraform_apply_role_arn" { value = aws_iam_role.tf_apply.arn }
output "ci_role_arn" { value = aws_iam_role.ci.arn }
