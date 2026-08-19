# ${{ values.displayName }}

${{ values.description }}

This repository was created by the **Monetized API interface** Golden Path in
Red Hat Developer Hub. It is contract-first and includes the complete API owner
surface:

- Go 1.26 service and tests;
- OpenAPI contract;
- OpenShift BuildConfig and ImageStream;
- hardened, mesh-enabled workload resources;
- Gateway API routes for API-key and Keycloak JWT traffic;
- RHCL AuthPolicy, PlanPolicy, and JWT RateLimitPolicy resources;
- APIProduct entries for both authentication choices;
- an OpenShift GitOps bootstrap Application.

## Develop

```bash
go test ./...
go run .
curl http://localhost:8080${{ values.apiPath }}
```

## Onboard through GitOps

The API Platform team reviews `bootstrap/argocd-application.yaml` before adding
it to the cluster. The generated Application deliberately has no automated sync:
the platform team performs the first and subsequent promotions after reviewing
the repository. OpenShift then builds the `main` branch into the integrated
registry and Argo CD reconciles `gitops/`.

The generated APIProduct and RHCL plan definitions are ready for catalog and
credential provisioning. The Billing administrator must also approve commercial
pricing for the product; API owners control technical limits, not prices.

Private repositories require both an Argo CD repository credential and an
OpenShift BuildConfig source secret. Public repositories work without either
credential.
