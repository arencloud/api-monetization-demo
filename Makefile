SHELL := /usr/bin/env bash

.PHONY: help validate test lifecycle-test preflight bootstrap render status verify portal demo reset-demo uninstall

help:
	@echo "Targets:"
	@echo "  validate   Render and statically validate every Kustomize package"
	@echo "  test       Run Go unit tests"
	@echo "  lifecycle-test Prove suspend, resume, cancel, cleanup, and resubscribe"
	@echo "  preflight  Check cluster access, version, permissions, and catalogs"
	@echo "  bootstrap  Install OpenShift GitOps and register the root application"
	@echo "  render     Render all Kustomize packages into stdout"
	@echo "  status     Show GitOps applications and operator subscriptions"
	@echo "  verify     Wait for secrets, databases, Keycloak, and realm readiness"
	@echo "  portal     Print the portal URL and generated developer/admin logins"
	@echo "  demo       Run API-key and JWT rate-limit and live-upgrade scenarios"
	@echo "  reset-demo Reset the demo subscription to the Free plan"
	@echo "  uninstall  Remove the complete demo after explicit confirmation"

validate:
	@./scripts/validate.sh

test:
	@go test ./...

lifecycle-test:
	@./scripts/lifecycle-test.sh

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
	@./scripts/lifecycle-test.sh

portal:
	@./scripts/portal.sh

demo:
	@./scripts/demo.sh

reset-demo:
	@./scripts/reset-demo.sh

uninstall:
	@./scripts/uninstall.sh
