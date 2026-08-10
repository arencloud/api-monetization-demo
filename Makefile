SHELL := /usr/bin/env bash

.PHONY: help validate test preflight bootstrap render status verify demo reset-demo

help:
	@echo "Targets:"
	@echo "  validate   Render and statically validate every Kustomize package"
	@echo "  test       Run Go unit tests"
	@echo "  preflight  Check cluster access, version, permissions, and catalogs"
	@echo "  bootstrap  Install OpenShift GitOps and register the root application"
	@echo "  render     Render all Kustomize packages into stdout"
	@echo "  status     Show GitOps applications and operator subscriptions"
	@echo "  verify     Wait for secrets, databases, Keycloak, and realm readiness"
	@echo "  demo       Run the API-key rate-limit and live-upgrade scenario"
	@echo "  reset-demo Reset the demo subscription to the Free plan"

validate:
	@./scripts/validate.sh

test:
	@go test ./...

preflight:
	@./scripts/preflight.sh

bootstrap:
	@./scripts/bootstrap.sh

render:
	@for package in $$(find applications bootstrap gitops operators platform -name kustomization.yaml -printf '%h\n' | sort); do \
		echo "# package: $$package"; \
		oc kustomize "$$package"; \
	done

status:
	@oc get applications.argoproj.io -n openshift-gitops
	@oc get subscriptions.operators.coreos.com -A

verify:
	@./scripts/verify.sh

demo:
	@./scripts/demo.sh

reset-demo:
	@./scripts/reset-demo.sh
