# ${{ values.displayName }}

${{ values.description }}

This repository was created by the **Monetized Camel API integration** Golden
Path. It uses the supported Red Hat Camel Quarkus platform and includes a
Kaoto-editable YAML route, authentication-specific OpenAPI contracts, browser-ready CORS handling, tests, OpenShift builds, Service Mesh,
Gateway API, RHCL authentication and plans, APIProducts, monitoring, and
governed self-service publication through Red Hat Developer Hub.

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

In Developer Hub's OpenAPI console, paste only the API-key credential. The
platform adds the required `APIKEY` authorization prefix automatically. Paste
only the JWT value for the Keycloak contract; Swagger adds the standard
`Bearer` prefix automatically.

Open `src/main/resources/routes/integration.camel.yaml` in Kaoto to extend the
route visually. Keep transformations in focused CDI beans so they remain easy
to unit test.

## Publish through Developer Hub

Keep both generated APIProducts in `Draft` while developing. When the contract,
implementation, mapping, and plan limits are ready, change both APIProducts to
`Published`, merge the changes into `main`, and return to this Component's
Overview page in Developer Hub. Select **Publish API** on the OpenShift Dev
Spaces card.

Developer Hub validates the repository contract, creates a constrained Argo CD
Application, and discovers the cluster's gateway and Keycloak hostnames. Argo CD
then builds `main` with the integrated registry and reconciles `gitops/`. The API
becomes available for consumer subscription only after the APIProduct reports
both `Ready=True` and `OpenAPISpecReady=True`. The reviewed APIProduct terms and
Connectivity Link limits publish all five plans. Accepted request or token usage
is sent to Billing automatically; rejected exchanges are not billed.

The checked-in `bootstrap/argocd-application.yaml` is retained as a reviewable
reference and disaster-recovery fallback. Normal publication must use Developer
Hub so cluster-specific routes and subscription enforcement are applied.

Private repositories require both an Argo CD repository credential and an
OpenShift BuildConfig source secret; public repositories need neither credential.
