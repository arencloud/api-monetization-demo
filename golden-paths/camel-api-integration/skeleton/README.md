# ${{ values.displayName }}

${{ values.description }}

This repository was created by the **Monetized Camel API integration** Golden
Path. It uses the supported Red Hat Camel Quarkus platform and includes a
Kaoto-editable YAML route, OpenAPI, tests, OpenShift builds, Service Mesh,
Gateway API, RHCL authentication and plans, APIProducts, monitoring, and an
OpenShift GitOps bootstrap Application.

## Develop and map

The Golden Path completion page opens this repository directly in Red Hat
OpenShift Dev Spaces. The checked-in `devfile.yaml` provides **test** and
**run** commands in the workspace task menu. The same commands work locally:

```bash
mvn quarkus:dev
curl -X POST http://localhost:8080${{ values.apiPath }} \
  -H 'content-type: application/json' \
  -d '{"correlationId":"order-42","payload":{"amount":49}}'
```

Open `src/main/resources/routes/integration.camel.yaml` in Kaoto to extend the
route visually. Keep transformations in focused CDI beans so they remain easy
to unit test.

## Onboard through GitOps

The API Platform team reviews `bootstrap/argocd-application.yaml`. The generated
Application deliberately has no automated sync, so each promotion remains a
reviewed platform action. After onboarding, OpenShift builds the repository into
the integrated registry and Argo CD reconciles `gitops/`. Private repositories
require both an Argo CD repository credential and an OpenShift BuildConfig
source secret; public repositories need neither credential.
