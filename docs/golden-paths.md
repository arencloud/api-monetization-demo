# API-owner Golden Paths

Red Hat Developer Hub exposes two governed Software Templates to members of the
`api-owners` group:

| Golden Path | Use when | Generated implementation |
| --- | --- | --- |
| Monetized API interface | Building a new contract-first HTTP API | Go 1.26 service, OpenAPI, tests, container build, GitOps, Gateway API, Service Mesh, RHCL policies and plans |
| Monetized Camel API integration | Mapping, enriching, routing, or orchestrating between complex interfaces | Red Hat build of Camel for Quarkus, Java 21, Kaoto-editable YAML route, OpenAPI, tests, and the same platform resources |

Every run creates a dedicated repository in the approved `arencloud` GitHub
organization, registers its `catalog-info.yaml` in Developer Hub, and returns
an **Open in OpenShift Dev Spaces** link. The link starts a workspace from the
new repository and its generated `devfile.yaml`; it does not add generated
source to this platform repository.

## Owner workflow

1. Sign in to Developer Hub as a member of `api-owners`.
2. Select **Golden Paths** in the main navigation.
3. Choose the normal API or Camel integration template.
4. Define the API identity, unique gateway path, approval mode, and Free and
   Developer technical limits.
5. Keep the initial catalog status at **Draft** while the API and commercial
   model are reviewed.
6. Provide a GitHub token for this task. The portable profile creates a public
   repository so catalog registration and OpenShift builds work immediately.
7. Select **Open in OpenShift Dev Spaces** from the task output. Dev Spaces
   clones the new repository and offers the generated test and run commands.
8. Develop through pull requests and let the repository's validation workflow
   test the application and render its GitOps resources.
9. Ask the API Platform team to review
   `bootstrap/argocd-application.yaml`, register commercial pricing in the
   Billing service, and perform the first Argo CD sync.
10. Change the APIProducts to `Published` only after the product is ready for
    consumer subscriptions.

Draft is the safe default: consumers do not receive a production product or
credentials before governance and billing onboarding are complete.

## GitHub credential

The form treats the token as a Developer Hub scaffolder secret. The token is
passed directly to `publish:github` for the current task and is not rendered
into the generated repository, Kubernetes resources, task parameters, or Git
history. It must belong to an identity allowed to create repositories in the
`arencloud` organization and write their initial contents.

For a longer-lived production setup, configure a centrally managed GitHub App
for Developer Hub and rotate its credentials through the platform secret
manager. The per-task token keeps this demonstration portable to a fresh
cluster without committing a bootstrap credential.

Public repositories require no read credential after creation. To enable
private repositories in a production overlay, configure a Developer Hub GitHub
App and change the template allowlist. Private repositories additionally require:

- an Argo CD repository credential in `openshift-gitops`;
- an OpenShift BuildConfig source secret in `api-monetization-apps`.

## Deployment boundary

Generated repositories cannot deploy arbitrary cluster resources. Their Argo
CD Applications use the `api-monetization-api-owners` AppProject, which permits
only approved namespaced workload, build, monitoring, Gateway API, RHCL, and
APIProduct kinds in `api-monetization-apps`. It excludes Secrets, RBAC, and all
cluster-scoped resources and accepts sources only from the approved GitHub
organization.

The generated Application intentionally omits automated sync. Repository
creation and catalog registration are self-service; promotion into the shared
runtime namespace is a reviewed platform operation.

After promotion, the generated Deployment labels associate the workload with
its Developer Hub Component. The RHDH Topology source-code action uses the
official `app.openshift.io/vcs-uri` and `app.openshift.io/vcs-ref` annotations
to reopen the same repository in Dev Spaces.

## Plans and commercial onboarding

The templates generate:

- API-key and Keycloak JWT routes and AuthPolicies;
- API-key `PlanPolicy` limits for Free, Developer, and unlimited Enterprise;
- a JWT `RateLimitPolicy` identity guard;
- separate APIProduct entries for API-key and OIDC discovery.

API owners define the technical safety envelope. Prices, included billable
units, subscription lifecycle, and invoice behavior remain centrally governed
by the monetization control plane. A new product must be added to that
commercial catalog before its APIProducts are published.

## Camel mapping development

The Camel Golden Path uses the Red Hat Quarkus and Camel BOMs at
`3.33.3.redhat-00001`. Its route lives at
`src/main/resources/routes/integration.camel.yaml` and can be opened in Kaoto.
Keep complex transformations in CDI beans, with the YAML route responsible for
transport and orchestration, so mappings remain unit-testable.

Local prerequisites are Java 21 and Maven. The generated GitHub workflow uses
Java 21 and runs the Camel tests on every pull request and `main` update.

## Platform validation

Run the fast structural checks with:

```bash
make validate
```

Render and compile representative projects from both templates with:

```bash
make golden-path-test
```

The build test requires Java 21, Maven, Go, and `oc`. CI runs the same command,
which proves the templates can create valid standalone projects rather than
only validating their source YAML.
