################################################################################
# Per-environment billing guardrails (AWS Budgets)
#   1. total monthly cost of everything tagged Environment=<env>
#   2. EC2 compute (incl. GPU instances) for the environment
# Notifications: 80% actual, 100% actual, 100% forecasted -> e-mail / SNS.
#
# Tag-filtered budgets need the "Environment" cost allocation tag activated
# (terraform/global: activate_cost_allocation_tags = true, after the tag has
# appeared in billing data — usually ~24h after the first tagged resource).
################################################################################

variable "name" { type = string }
variable "environment" { type = string }

variable "monthly_budget_usd" {
  type = number
}

variable "compute_budget_usd" {
  description = "EC2 compute (CPU + GPU nodes) monthly budget."
  type        = number
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "sns_topic_arns" {
  type    = list(string)
  default = []
}

locals {
  # Budgets tag filter syntax is "user:<TagKey>$<TagValue>"
  tag_filter = [join("$", ["user:Environment", var.environment])]

  notifications = [
    { type = "ACTUAL", threshold = 80 },
    { type = "ACTUAL", threshold = 100 },
    { type = "FORECASTED", threshold = 100 },
  ]
  notify = length(var.alert_emails) + length(var.sns_topic_arns) > 0
}

resource "aws_budgets_budget" "total" {
  name         = "${var.name}-monthly-total"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = local.tag_filter
  }

  dynamic "notification" {
    for_each = local.notify ? local.notifications : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = var.alert_emails
      subscriber_sns_topic_arns  = var.sns_topic_arns
    }
  }
}

resource "aws_budgets_budget" "compute" {
  name         = "${var.name}-monthly-ec2-compute"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.compute_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = local.tag_filter
  }

  cost_filter {
    name   = "Service"
    values = ["Amazon Elastic Compute Cloud - Compute"]
  }

  dynamic "notification" {
    for_each = local.notify ? local.notifications : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = var.alert_emails
      subscriber_sns_topic_arns  = var.sns_topic_arns
    }
  }
}

output "budget_names" {
  value = [aws_budgets_budget.total.name, aws_budgets_budget.compute.name]
}
