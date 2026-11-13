################################################################################
# RDS PostgreSQL shared by platform services
#   jupyterhub      -> JupyterHub state (users, servers, tokens)
#   argo_workflows  -> Argo Workflows archive (workflow history)
#
# Credentials live in Secrets Manager (KMS-encrypted) under <name>/rds/*.
# In-cluster, External Secrets Operator syncs them; the platform-config chart's
# db-init Job creates the per-app roles + databases idempotently.
################################################################################

variable "name" { type = string }
variable "vpc_id" { type = string }
variable "db_subnet_group_name" { type = string }
variable "allowed_security_group_ids" {
  description = "Static keys -> SG ids (map so for_each works when ids are unknown at plan time)."
  type        = map(string)
}
variable "kms_key_arn" { type = string }

variable "instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "engine_version" {
  description = "Major version only -> RDS picks the current default minor; auto minor upgrades on."
  type        = string
  default     = "16"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "app_databases" {
  type    = list(string)
  default = ["jupyterhub", "argo_workflows"]
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "PostgreSQL from EKS nodes only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds" {
  for_each                     = var.allowed_security_group_ids
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from cluster nodes"
}

resource "random_password" "master" {
  length  = 32
  special = false
}

resource "random_password" "app" {
  for_each = toset(var.app_databases)
  length   = 32
  special  = false
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.10"

  identifier = "${var.name}-postgres"

  engine                     = "postgres"
  engine_version             = var.engine_version
  family                     = "postgres${var.engine_version}"
  major_engine_version       = var.engine_version
  instance_class             = var.instance_class
  auto_minor_version_upgrade = true

  allocated_storage     = 50
  max_allocated_storage = 200
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name                     = "platform"
  username                    = "platform_admin"
  port                        = 5432
  manage_master_user_password = false
  password                    = random_password.master.result

  multi_az               = var.multi_az
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  backup_retention_period          = var.backup_retention_days
  backup_window                    = "03:00-04:00"
  maintenance_window               = "Sun:04:30-Sun:05:30"
  deletion_protection              = var.deletion_protection
  skip_final_snapshot              = !var.deletion_protection
  final_snapshot_identifier_prefix = "${var.name}-final"
  copy_tags_to_snapshot            = true

  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn
  create_monitoring_role          = true
  monitoring_interval             = 60
  monitoring_role_name            = "${var.name}-rds-monitoring"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  parameters = [
    { name = "rds.force_ssl", value = "1" },
    { name = "log_min_duration_statement", value = "1000" },
  ]
}

# ---------------- Secrets Manager (consumed by External Secrets) ----------------
resource "aws_secretsmanager_secret" "master" {
  name                    = "${var.name}/rds/master"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = "platform_admin"
    password = random_password.master.result
    host     = module.rds.db_instance_address
    port     = 5432
    dbname   = "platform"
  })
}

resource "aws_secretsmanager_secret" "app" {
  for_each                = toset(var.app_databases)
  name                    = "${var.name}/rds/${each.key}"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app" {
  for_each  = toset(var.app_databases)
  secret_id = aws_secretsmanager_secret.app[each.key].id
  secret_string = jsonencode({
    username = each.key
    password = random_password.app[each.key].result
    host     = module.rds.db_instance_address
    port     = 5432
    dbname   = each.key
  })
}

output "address" { value = module.rds.db_instance_address }
output "port" { value = module.rds.db_instance_port }
output "secret_prefix" { value = "${var.name}/rds/" }
output "security_group_id" { value = aws_security_group.rds.id }
