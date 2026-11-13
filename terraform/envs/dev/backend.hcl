bucket       = "aiml-tfstate-__AWS_ACCOUNT_ID__"
key          = "stack/dev/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
kms_key_id   = "alias/aiml-tfstate" # customer-managed key (terraform/global)
use_lockfile = true # S3-native state locking (Terraform >= 1.10)
