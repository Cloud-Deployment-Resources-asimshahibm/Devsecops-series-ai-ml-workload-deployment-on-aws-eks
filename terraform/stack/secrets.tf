################################################################################
# Application secrets in AWS Secrets Manager (KMS-encrypted).
# Synced into the cluster by External Secrets (charts/platform-config).
################################################################################

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "${local.name}/grafana/admin"
  kms_key_id              = module.kms.key_arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  })
}

# GitHub OAuth App for JupyterHub login. Terraform creates the container with
# placeholder values; set the real ones once (runbook Phase 5):
#   aws secretsmanager put-secret-value --secret-id aiml-<env>/jupyterhub/github-oauth \
#     --secret-string '{"client_id":"...","client_secret":"..."}'
resource "aws_secretsmanager_secret" "jupyterhub_oauth" {
  name                    = "${local.name}/jupyterhub/github-oauth"
  kms_key_id              = module.kms.key_arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "jupyterhub_oauth" {
  secret_id     = aws_secretsmanager_secret.jupyterhub_oauth.id
  secret_string = jsonencode({ client_id = "CHANGE_ME", client_secret = "CHANGE_ME" })

  lifecycle {
    ignore_changes = [secret_string] # managed out-of-band after creation
  }
}

# Read-only Elasticsearch user used by the Grafana "Elasticsearch (ELK)" datasource
resource "random_password" "es_grafana" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "es_grafana" {
  name                    = "${local.name}/elasticsearch/grafana"
  kms_key_id              = module.kms.key_arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "es_grafana" {
  secret_id     = aws_secretsmanager_secret.es_grafana.id
  secret_string = jsonencode({ username = "grafana", password = random_password.es_grafana.result })
}

# API keys for the ml-inference API (/v1/*). Rotate by tainting the random_password.
resource "random_password" "inference_api_key" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "inference_api_keys" {
  name                    = "${local.name}/inference/api-keys"
  kms_key_id              = module.kms.key_arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "inference_api_keys" {
  secret_id     = aws_secretsmanager_secret.inference_api_keys.id
  secret_string = jsonencode({ keys = random_password.inference_api_key.result })
}
