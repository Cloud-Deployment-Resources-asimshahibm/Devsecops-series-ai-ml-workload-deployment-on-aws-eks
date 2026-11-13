bucket       = "aiml-tfstate-__AWS_ACCOUNT_ID__"
key          = "stack/prod/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
kms_key_id   = "alias/aiml-tfstate" # customer-managed key (terraform/global)
use_lockfile = true
