# golden-path-k8s: every developer-facing command (CLAUDE.md "Commands"). Runs in Git Bash, WSL, Linux and macOS.
# Tools come from ./.bin (make tools), pinned in tools/versions.env (D-039, D-048).
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export PATH := $(ROOT)/.bin:$(PATH)
# The kind targets use their own kubeconfig, refreshed from kind, so a change of the global current context (for example
# Docker Desktop's own Kubernetes) can't redirect them. Use it yourself with: export KUBECONFIG=$$PWD/.kube/golden-path.yaml
export KUBECONFIG := $(ROOT)/.kube/golden-path.yaml
KUBECONFIG_REFRESH = @mkdir -p $(ROOT)/.kube && kind export kubeconfig --name golden-path --kubeconfig $(KUBECONFIG) >/dev/null \
	|| { echo "FAIL: no kind cluster 'golden-path' (run make kind-up)"; exit 1; }
KIND_CONTEXT := kind-golden-path
# What a run tested (D-069): the revision, whether the tree was dirty, and the CI-built fixture digests.
EVIDENCE = mkdir -p .e2e-reports && { echo "revision: $$(git rev-parse HEAD)$$(git diff --quiet HEAD || echo ' (dirty)')"; \
	echo "date: $$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat tests/e2e/lib/images.env | grep -v '^\#'; } >.e2e-reports/evidence.txt && cat .e2e-reports/evidence.txt

JOURNEY ?=
E2E_DIRS := $(filter-out lib,$(sort $(notdir $(patsubst %/,%,$(wildcard tests/e2e/*/)))))

PROFILE ?= local

.PHONY: hooks help doctor tools preflight kind-up kind-sync kind-down validate test-policies e2e e2e-all verify-docs \n	aks-preflight aks-plan aks-up aks-bootstrap aks-down aks-verify-teardown

help: ## List targets
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-15s %s\n", $$1, $$2}'

hooks: ## Enable the repo's Git hooks (worktree rule, D-089): the primary checkout stays on main
	git config core.hooksPath .githooks
	@echo "Git hooks enabled (.githooks). Work on branches in worktrees: git worktree add ../golden-path-k8s-<task> -b <branch> origin/main"

doctor: ## Check prerequisites: make doctor [PROFILE=local|docs|github|cloud|all]
	bash scripts/doctor.sh $(PROFILE)

tools: ## Install pinned, checksum-verified CLIs into ./.bin
	bash tools/install.sh

preflight: ## Check Docker, memory (>=8 GiB) and cgroup v2 before kind-up
	bash infra/kind/bootstrap.sh preflight

kind-up: tools ## Create the kind platform (preflight → cluster → Cilium → GitOps)
	bash infra/kind/bootstrap.sh up

kind-sync: ## Re-apply Argo CD's values and push the tracked working tree to the in-cluster Gitea
	$(KUBECONFIG_REFRESH)
	bash infra/kind/bootstrap.sh sync-git

kind-down: ## Delete the kind cluster
	bash infra/kind/bootstrap.sh down

validate: tools ## All static checks
	bash scripts/validate.sh

test-policies: tools ## kyverno test for every policy (pass and fail cases)
	bash scripts/test-policies.sh

e2e: tools ## Run one Chainsaw journey on kind: make e2e JOURNEY=<dir>
	$(KUBECONFIG_REFRESH)
	@$(EVIDENCE)
	@[ -n "$(JOURNEY)" ] || { echo "usage: make e2e JOURNEY=<dir>  (one of: $(E2E_DIRS))"; exit 2; }
	@[ -d tests/e2e/$(JOURNEY) ] || { echo "no such journey: tests/e2e/$(JOURNEY)"; exit 2; }
	@mkdir -p .e2e-reports
	chainsaw test --kube-context $(KIND_CONTEXT) --test-dir tests/e2e/$(JOURNEY) --config tests/e2e/chainsaw-config.yaml --no-color

e2e-all: tools ## Run every Chainsaw suite on kind
	$(KUBECONFIG_REFRESH)
	@$(EVIDENCE)
	@mkdir -p .e2e-reports
	chainsaw test --kube-context $(KIND_CONTEXT) --test-dir tests/e2e --config tests/e2e/chainsaw-config.yaml --no-color

# AKS (D-083, D-084): every target goes through infra/aks/aks.sh, which enforces the subscription confirmation, the
# timeouts, the teardown owner and the teardown check. GP_ENV selects infra/envs/<env> (default sandbox).
aks-preflight: tools ## Cloud preflight, read-only (= make doctor PROFILE=cloud)
	bash infra/aks/aks.sh preflight

aks-plan: tools ## terraform plan for infra/envs/<GP_ENV> (after the preflight)
	bash infra/aks/aks.sh plan

aks-up: ## Apply the reviewed plan (needs GP_CONFIRM_SUBSCRIPTION=<subscription id>; billable)
	bash infra/aks/aks.sh up

aks-bootstrap: ## Argo CD, cluster Secrets, root app and EnvironmentConfig on the AKS clusters
	bash infra/aks/aks.sh bootstrap

aks-down: ## Drain XRs, terraform destroy, verify nothing is left
	bash infra/aks/aks.sh down

aks-verify-teardown: ## Assert from Azure that nothing from the environment remains
	bash infra/aks/aks.sh verify-teardown

verify-docs: ## Documentation gate (D-035)
	bash scripts/verify-docs.sh
