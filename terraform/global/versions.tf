terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }

  # Chicken-and-egg: this stack CREATES the state bucket, so the first apply
  # uses local state. scripts/bootstrap-global.sh then writes backend.tf and
  # runs `terraform init -migrate-state` to move the state into S3.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = var.project
      Stack      = "global"
      ManagedBy  = "terraform"
      Repository = "${var.github_org}/${var.github_repo}"
    }
  }
}
