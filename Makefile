SHELL := /bin/bash
ENV ?= dev

.PHONY: help configure global deploy wait access smoke test lint tf-fmt tf-validate helm-lint train destroy

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

configure: ## Render account id / admin role placeholders
	scripts/configure.sh

global: ## Phase 1: state bucket, GitHub OIDC roles, ECR
	scripts/bootstrap-global.sh

deploy: ## Phase 3: provision ENV (dev|prod) with Terraform + GitOps bootstrap
	scripts/deploy-env.sh $(ENV)

wait: ## Watch Argo CD apps until Synced/Healthy
	scripts/wait-for-apps.sh

access: ## Port-forward all UIs and print credentials
	ENV=$(ENV) scripts/access.sh

smoke: ## End-to-end checks against the current kube context
	scripts/smoke-test.sh $(ENV)

train: ## Submit the training pipeline (needs argo CLI)
	argo submit -n ml-training --from workflowtemplate/ml-training-pipeline -p use-ray=true --watch

test: ## Python unit tests
	cd ml && pytest -q

lint: tf-fmt helm-lint ## All linters
	cd ml && ruff check .

tf-fmt:
	terraform fmt -check -recursive terraform

tf-validate:
	for d in terraform/global terraform/stack; do (cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate); done

helm-lint:
	for c in charts/* argocd/app-of-apps; do helm lint $$c -f $$c/values.yaml -f $$c/values-$(ENV).yaml; done

destroy: ## Tear down ENV safely (k8s-owned AWS resources first)
	scripts/teardown.sh $(ENV)
