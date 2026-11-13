################################################################################
# AWS WAF v2 web ACL for the internet-facing ALB (ml-inference API, JupyterHub).
# Attached by the AWS Load Balancer Controller through the ingress annotation
# alb.ingress.kubernetes.io/wafv2-acl-arn (scripts/render-security-outputs.sh).
################################################################################

variable "name" { type = string }

variable "rate_limit_per_5min" {
  description = "Requests per 5 minutes per client IP before blocking."
  type        = number
  default     = 2000
}

variable "max_body_kb" {
  description = "Largest request body accepted (prediction batches)."
  type        = number
  default     = 256
}

variable "kms_key_arn" { type = string }

locals {
  managed = {
    AWSManagedRulesCommonRuleSet          = 10
    AWSManagedRulesAmazonIpReputationList = 30
    AWSManagedRulesAnonymousIpList        = 40
  }
}

resource "aws_wafv2_web_acl" "this" {
  name  = "${var.name}-alb"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.managed
    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key

          # prediction batches are JSON arrays larger than the 8 KB CRS body default
          dynamic "rule_action_override" {
            for_each = rule.key == "AWSManagedRulesCommonRuleSet" ? ["SizeRestrictions_BODY"] : []
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  # Known bad inputs incl. Log4Shell (CVE-2021-44228) JNDI lookups
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # our own body-size cap replaces the CRS 8 KB rule above
  rule {
    name     = "body-size-limit"
    priority = 50
    action {
      block {}
    }
    statement {
      size_constraint_statement {
        comparison_operator = "GT"
        size                = var.max_body_kb * 1024
        field_to_match {
          body {
            oversize_handling = "MATCH"
          }
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "body-size-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "per-ip-rate-limit"
    priority = 60
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "per-ip-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-alb"
    sampled_requests_enabled   = true
  }
}

# WAF logs: log group name must start with aws-waf-logs-
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  redacted_fields {
    single_header {
      name = "x-api-key"
    }
  }
}

output "web_acl_arn" { value = aws_wafv2_web_acl.this.arn }
