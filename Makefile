SHELL := /usr/bin/env bash

.PHONY: help validate test rhdh-plugin-test lifecycle-test multi-product-test ai-model-test ai-monetization-test ai-demo promotion-status preflight bootstrap render status verify observe grafana portal hub demo metered-demo showcase reset-demo uninstall

help:
	@echo "Targets:"
	@echo "  validate   Render and statically validate every Kustomize package"
	@echo "  test       Run Go unit tests"
	@echo "  rhdh-plugin-test Build, test, and reproduce the custom RHDH plugin artifact"
	@echo "  lifecycle-test Prove suspend, resume, cancel, cleanup, and resubscribe"
	@echo "  multi-product-test Prove independent Inventory and Payment subscriptions"
	@echo "  ai-model-test Prove CPU-only OpenShift AI chat inference"
	@echo "  ai-monetization-test Prove API-key/JWT AI inference and token billing"
	@echo "  ai-demo    Prove Free AI token exhaustion and a live Developer upgrade"
	@echo "  promotion-status Prove Argo revision, Build, image tag, and running digest provenance"
	@echo "  preflight  Check cluster access, version, permissions, and catalogs"
	@echo "  bootstrap  Install OpenShift GitOps and register the root application"
	@echo "  render     Render all Kustomize packages into stdout"
	@echo "  status     Show GitOps applications and operator subscriptions"
	@echo "  verify     Wait for secrets, databases, Keycloak, and realm readiness"
	@echo "  observe    Show live accepted, limited, overage, and revenue metrics"
	@echo "  grafana    Print the managed Grafana URL and SSO/break-glass logins"
	@echo "  portal     Print the portal URL and generated developer/admin logins"
	@echo "  hub        Print the Developer Hub URL and Keycloak test logins"
	@echo "  demo       Run API-key and JWT rate-limit and live-upgrade scenarios"
	@echo "  metered-demo Generate real Pay-as-you-go usage and a draft invoice"
	@echo "  showcase   Run the complete verified demo and restore reusable state"
	@echo "  reset-demo Reset the demo subscription to the Free plan"
	@echo "  uninstall  Remove the complete demo after explicit confirmation"

validate:
	@./scripts/validate.sh

test:
	@go test ./applications/... ./internal/...

rhdh-plugin-test:
	@./plugins/rhdh-policy-catalog/scripts/container-build.sh

lifecycle-test:
	@./scripts/lifecycle-test.sh

multi-product-test:
	@./scripts/multi-product-test.sh

ai-model-test:
	@./scripts/ai-model-test.sh

ai-monetization-test:
	@./scripts/ai-monetization-test.sh

ai-demo:
	@./scripts/ai-demo.sh

promotion-status:
	@./scripts/build-promotion-status.sh

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
	@./scripts/build-promotion-status.sh
	@./scripts/lifecycle-test.sh

observe:
	@./scripts/observe.sh

grafana:
	@./scripts/grafana.sh

portal:
	@./scripts/portal.sh

hub:
	@./scripts/hub.sh

demo:
	@./scripts/demo.sh

metered-demo:
	@./scripts/metered-demo.sh

showcase:
	@./scripts/showcase.sh

reset-demo:
	@./scripts/reset-demo.sh

uninstall:
	@./scripts/uninstall.sh
