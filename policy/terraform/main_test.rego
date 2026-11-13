package main

import rego.v1

plan(env, rcs) := {"variables": {"environment": {"value": env}}, "resource_changes": rcs}

rc(type, after) := {"address": sprintf("%s.test", [type]), "type": type, "change": {"actions": ["create"], "after": after}}

test_public_s3_denied if {
	count(deny) > 0 with input as plan("dev", [rc("aws_s3_bucket_public_access_block", {"block_public_acls": false, "block_public_policy": true, "ignore_public_acls": true, "restrict_public_buckets": true})])
}

test_private_s3_allowed if {
	count(deny) == 0 with input as plan("dev", [rc("aws_s3_bucket_public_access_block", {"block_public_acls": true, "block_public_policy": true, "ignore_public_acls": true, "restrict_public_buckets": true})])
}

test_public_rds_denied if {
	count(deny) > 0 with input as plan("dev", [rc("aws_db_instance", {"publicly_accessible": true, "storage_encrypted": true})])
}

test_kms_rotation_required if {
	count(deny) > 0 with input as plan("dev", [rc("aws_kms_key", {"enable_key_rotation": false})])
}

test_ssh_from_internet_denied if {
	count(deny) > 0 with input as plan("dev", [rc("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0", "from_port": 22})])
}

test_https_from_internet_allowed if {
	count(deny) == 0 with input as plan("dev", [rc("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0", "from_port": 443})])
}

eks(cidrs) := rc("aws_eks_cluster", {"encryption_config": [{"resources": ["secrets"]}], "vpc_config": [{"endpoint_public_access": true, "public_access_cidrs": cidrs}]})

test_open_eks_endpoint_denied_in_prod if {
	count(deny) > 0 with input as plan("prod", [eks(["0.0.0.0/0"])])
}

test_open_eks_endpoint_only_warns_in_dev if {
	count(deny) == 0 with input as plan("dev", [eks(["0.0.0.0/0"])])
	count(warn) == 1 with input as plan("dev", [eks(["0.0.0.0/0"])])
}

test_mutable_ecr_denied if {
	count(deny) > 0 with input as plan("dev", [rc("aws_ecr_repository", {"image_tag_mutability": "MUTABLE", "image_scanning_configuration": [{"scan_on_push": true}]})])
}

test_admin_inline_policy_denied if {
	doc := json.marshal({"Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]})
	count(deny) > 0 with input as plan("dev", [rc("aws_iam_policy", {"policy": doc})])
}

test_scoped_policy_allowed if {
	doc := json.marshal({"Statement": [{"Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:aws:s3:::b/*"}]})
	count(deny) == 0 with input as plan("dev", [rc("aws_iam_policy", {"policy": doc})])
}
