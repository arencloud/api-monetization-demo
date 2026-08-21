# ${{ values.displayName }}

${{ values.description }}

This repository was created by the **Monetized API interface** Golden Path in
Red Hat Developer Hub. It is contract-first and includes the complete API owner
surface:

- Go 1.26 service and tests;
- separate OpenAPI contracts for API-key and Keycloak Bearer JWT consumers;
- browser-ready CORS preflight and response handling for Developer Hub's OpenAPI console;
- OpenShift BuildConfig and ImageStream;
- hardened, mesh-enabled workload resources;
- Gateway API routes for API-key and Keycloak JWT traffic;
- RHCL AuthPolicy, PlanPolicy, and JWT RateLimitPolicy resources;
- APIProduct entries for both authentication choices;
- governed self-service publication through Red Hat Developer Hub.

## Develop

The Golden Path completion page opens this repository directly in Red Hat
OpenShift Dev Spaces. The checked-in `devfile.yaml` provides **test** and
**run** commands in the workspace task menu. The same commands work locally:

```bash
go test ./...
go run .
curl http://localhost:8080${{ values.apiPath }}
```

In Developer Hub's OpenAPI console, paste `APIKEY <credential>` into the API-key
authorization field. The Keycloak contract accepts the JWT alone and adds the
standard `Bearer` prefix automatically.

## Publish through Developer Hub

Keep both generated APIProducts in `Draft` while developing. When the contract,
implementation, and plan limits are ready, change both APIProducts to
`Published`, merge the changes into `main`, and return to this Component's
Overview page in Developer Hub. Select **Publish API** on the OpenShift Dev
Spaces card.

Developer Hub validates the repository contract, creates a constrained Argo CD
Application, and discovers the cluster's gateway and Keycloak hostnames. Argo CD
then builds `main` with the integrated registry and reconciles `gitops/`. The API
becomes available for consumer subscription only after the APIProduct reports
both `Ready=True` and `OpenAPISpecReady=True`. The reviewed APIProduct terms and
Connectivity Link limits publish all five plans. Accepted request or token usage
is sent to Billing automatically; rejected responses are recorded with zero units.

The checked-in `bootstrap/argocd-application.yaml` is retained as a reviewable
reference and disaster-recovery fallback. Normal publication must use Developer
Hub so cluster-specific routes and subscription enforcement are applied.

Private repositories require both an Argo CD repository credential and an
OpenShift BuildConfig source secret. Public repositories work without either
credential.
