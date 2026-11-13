# Policy-as-code gate on `terraform show -json tfplan` (conftest).
# Runs in .github/workflows/terraform.yml before every apply; a deny fails the job.
package main

import rego.v1

creating_or_updating(rc) if {
	some action in rc.change.actions
	action in {"create", "update"}
}

changes contains rc if {
	some rc in input.resource_changes
	creating_or_updating(rc)
}

environment := input.variables.environment.value

# ---------------------------------------------------------------- storage & data
deny contains msg if {
	some rc in changes
	rc.type == "aws_s3_bucket_public_access_block"
	some flag in ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]
	rc.change.after[flag] != true
	msg := sprintf("%s: S3 public access block must set %s = true", [rc.address, flag])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_s3_bucket_server_side_encryption_configuration"
	some rule in rc.change.after.rule
	some enc in rule.apply_server_side_encryption_by_default
	enc.sse_algorithm != "aws:kms"
	msg := sprintf("%s: S3 buckets must use SSE-KMS (got %s)", [rc.address, enc.sse_algorithm])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_db_instance"
	rc.change.after.publicly_accessible == true
	msg := sprintf("%s: RDS must not be publicly accessible", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_db_instance"
	rc.change.after.storage_encrypted != true
	msg := sprintf("%s: RDS storage must be encrypted", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_efs_file_system"
	rc.change.after.encrypted != true
	msg := sprintf("%s: EFS must be encrypted at rest", [rc.address])
}

# ---------------------------------------------------------------- encryption & keys
deny contains msg if {
	some rc in changes
	rc.type == "aws_kms_key"
	rc.change.after.enable_key_rotation != true
	msg := sprintf("%s: KMS keys must have automatic rotation enabled", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_eks_cluster"
	count(object.get(rc.change.after, "encryption_config", [])) == 0
	msg := sprintf("%s: EKS secrets must be envelope-encrypted with KMS", [rc.address])
}

# ---------------------------------------------------------------- network exposure
deny contains msg if {
	some rc in changes
	rc.type == "aws_vpc_security_group_ingress_rule"
	rc.change.after.cidr_ipv4 == "0.0.0.0/0"
	not rc.change.after.from_port in {80, 443}
	msg := sprintf("%s: ingress from 0.0.0.0/0 is only allowed on 80/443", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_security_group_rule"
	rc.change.after.type == "ingress"
	"0.0.0.0/0" in object.get(rc.change.after, "cidr_blocks", [])
	not rc.change.after.from_port in {80, 443}
	msg := sprintf("%s: ingress from 0.0.0.0/0 is only allowed on 80/443", [rc.address])
}

open_api_endpoint(rc) if {
	rc.type == "aws_eks_cluster"
	some vpc in rc.change.after.vpc_config
	vpc.endpoint_public_access == true
	"0.0.0.0/0" in vpc.public_access_cidrs
}

deny contains msg if {
	environment == "prod"
	some rc in changes
	open_api_endpoint(rc)
	msg := sprintf("%s: prod EKS API endpoint must not be open to 0.0.0.0/0 (set cluster_endpoint_public_access_cidrs)", [rc.address])
}

warn contains msg if {
	environment != "prod"
	some rc in changes
	open_api_endpoint(rc)
	msg := sprintf("%s: EKS API endpoint open to 0.0.0.0/0 (acceptable for dev only)", [rc.address])
}

# ---------------------------------------------------------------- supply chain & audit
deny contains msg if {
	some rc in changes
	rc.type == "aws_ecr_repository"
	rc.change.after.image_tag_mutability != "IMMUTABLE"
	msg := sprintf("%s: ECR repositories must use immutable tags", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_ecr_repository"
	some cfg in rc.change.after.image_scanning_configuration
	cfg.scan_on_push != true
	msg := sprintf("%s: ECR scan on push must be enabled", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_cloudtrail"
	rc.change.after.enable_log_file_validation != true
	msg := sprintf("%s: CloudTrail log file validation must be enabled", [rc.address])
}

# ---------------------------------------------------------------- IAM
deny contains msg if {
	some rc in changes
	rc.type in {"aws_iam_policy", "aws_iam_role_policy"}
	doc := json.unmarshal(rc.change.after.policy)
	some stmt in as_array(doc.Statement)
	stmt.Effect == "Allow"
	"*" in as_array(stmt.Action)
	"*" in as_array(stmt.Resource)
	msg := sprintf("%s: inline/customer policies must not grant Action * on Resource *", [rc.address])
}

as_array(x) := x if is_array(x)

as_array(x) := [x] if not is_array(x)
