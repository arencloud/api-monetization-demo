# Architecture

[Project home](../README.md) · [Documentation](README.md) · **Architecture** · [Deploy](deployment.md) · [Demo](demo-runbook.md) · [Golden Paths](golden-paths.md)

> **Design rule:** request-time enforcement belongs in the data plane;
> products, subscriptions, accepted usage, pricing, and invoices belong in the
> commercial control plane.

## System context

The platform separates the customer-facing product lifecycle from request-time
enforcement. This prevents the gateway from becoming a billing database and
allows commercial workflows to evolve without changing API workloads.

![Detailed API Monetization architecture](assets/api-monetization-architecture.png)

### How to read the diagram

| Flow | Meaning |
| --- | --- |
| **Solid** | Synchronous API request path from consumer to workload |
| **Blue dashed** | Identity, product metadata, usage, and telemetry signals |
| **Green dashed** | Policy, secret, commercial-state, and GitOps reconciliation |

The public request path is deliberately short:

```text
OpenShift Route → Gateway API → Connectivity Link → Service Mesh → API
```

The OpenShift Route path is always available. A cluster with a functioning
Service LoadBalancer provider additionally exposes the same Gateway through its
assigned external address; the request-time policy path is unchanged.

## Responsibilities

| Capability | Owner |
| --- | --- |
| API catalog, documentation, subscription and credentials UX | Red Hat Developer Hub, custom monetization extension, and Kuadrant plugins |
| OAuth2/OIDC identities, JWTs, clients, roles | Red Hat build of Keycloak |
| Database lifecycle, failover, backup hooks | CloudNativePG certified Operator |
| Secret synchronization and demo credential generation | External Secrets Operator for Red Hat OpenShift |
| Credential-to-customer mapping and API-key lifecycle | Subscription service and its datastore |
| JWT/API-key validation and external authorization | RHCL `AuthPolicy` / Authorino |
| Quotas and request/token rate limiting | RHCL `RateLimitPolicy` / `TokenRateLimitPolicy` / Limitador |
| North-south routing, TLS, DNS | Gateway API and RHCL policies |
| East-west identity, encryption, routing, telemetry | Red Hat OpenShift Service Mesh |
| Request telemetry | OpenTelemetry, Prometheus, Loki, and Tempo |
| Plan state, upgrades, rating, invoices | Monetization control plane and PostgreSQL |
| Operational and business visualization | Grafana Operator, Grafana, and Kiali |
| Desired state and promotion | OpenShift GitOps |

Red Hat Developer Hub is the unified presentation layer, not a replacement for
the request-time enforcement or billing engines. The Kuadrant plugins provide
the operator-native catalog projection and policy details. The custom
monetization
frontend presents subscriptions, accepted request/token usage, projected
revenue, and invoices, and provides subscription, plan, cancellation, and
credential lifecycle actions. Its backend is the only browser-facing bridge:
RHDH RBAC authorizes each read or mutation, then the monetization control plane
verifies the forwarded Keycloak token and resolves the subject to its
PostgreSQL customer. No browser-supplied customer identifier is trusted. The
existing portal remains available as a rollback path and for the AI playground.

Every published `APIProduct` is presented as a production API. Its
`monetization.arencloud.com/product` annotation maps the API-key and OIDC/JWT
presentations to one logical commercial product. No interactive RHDH role can
create, update, delete, or approve Kuadrant `APIKey` resources. Users first
create a subscription and the control plane alone provisions the
operator-native credential. At request time Authorino resolves the same active
subscription for
both authentication paths, so catalogue visibility never implies entitlement.
For consumers, production rows without an active entitlement are greyed in
both the Kuadrant product view and the Developer Hub APIs explorer, and their
detail links are disabled; the Billing subscription action remains available.
Both authentication rows unlock as soon as the shared subscription becomes
active. Frontend releases use a new versioned dynamic-plugin artifact
path so existing RHDH clients cannot retain an earlier module-federation bundle
under the same package URL.
RHDH does not permit dynamic routes to override built-in routes other than the
home page. The supported main-menu configuration therefore points the standard
**APIs** navigation item at the extension's unique `/monetized-apis` route;
the built-in `/api-docs` route is not shadowed.

Each governed HTTPRoute has its own `APIProduct` presentation in RHDH. The
three API-key routes advertise API-key authentication and receive credentials
only through the subscription workflow. The matching JWT routes advertise OIDC,
publish the discovered Red Hat build of Keycloak token endpoint, and accept
short-lived bearer tokens without creating an `APIKey` object. A GitOps hook
replaces the portable issuer placeholder with the admitted Keycloak Route and
adds the OpenShift router CA to Authorino and the developer-portal controller;
no cluster-specific applications domain is stored in Git.

RHDH uses a dedicated service account. API owners retain APIProduct management,
but the Kuadrant integration has no APIKey or credential Secret access.
Policies, Gateway API, and catalog metadata needed for presentation are visible.
Keycloak supplies users and groups to the
catalog through a confidential, read-only service account. `api-consumers`,
`api-owners`, and `api-admins` map to the matching RHDH RBAC roles, and newly
registered developers enter the consumer group by default.
An external conditional RBAC policy limits consumers to catalog entities of
Kind `API` and `Group`, allowing API ownership relations to resolve while
Component/Service entities and their development controls remain owner and
administrator concerns. API-owner Components with a validated
`github.com/project-slug` annotation receive an **Open in Dev Spaces** action,
including projects created by earlier Golden Path template versions. Current
Golden Path repositories additionally receive a **Publish API** action. The
backend accepts only the configured GitHub organization, validates catalog
ownership and the governed resource set, and creates an Argo CD Application in
the restricted `api-monetization-api-owners` AppProject. It discovers Route and
Keycloak hosts at publication time and overlays mandatory active-subscription
authorization and plan-aware JWT limits; API owners cannot replace those
platform controls.

`TokenRateLimitPolicy` discovery is implemented in the custom backend because
the tested Kuadrant 0.4.0 backend does not expose that CRD. The endpoint uses
the dedicated RHDH service account and the
`api-monetization.tokenratelimitpolicy.list` permission. Billing has distinct
`read.own` and `read.all` permissions. Consumer lifecycle actions additionally
require `subscription.create.own`, `subscription.update.own`, or
`subscription.delete.own`; Keycloak performs the matching developer or
administrator role check again at the control-plane boundary.
The frontend extension explicitly registers RHDH's generic `auth.oidc` API
factory. This reuses the signed-in Keycloak session to obtain the short-lived
provider access token; no token or customer identifier is stored in browser
configuration.

The browser portal is a public PKCE client in Keycloak. Human administrators
receive the `monetization-admin` realm role and developers receive the separate
`monetization-developer` role. Deterministic verification uses confidential
service clients with the same narrow role boundaries and generated secrets.
The control-plane service verifies token signature, issuer, audience, expiry,
and role before serving APIs. Developers can access only their subject-mapped
customer, subscriptions, and credentials. Entitlement lookups and usage
ingestion listen on a separate internal port that is not exposed by the portal
Route.

Self-service credential issuance remains operator-native. The control plane
creates a namespaced External Secrets `Password` generator and `ExternalSecret`,
then creates the RHCL `APIKey` referencing the generated Secret. RHCL approves
and labels the credential for request-time authentication. The portal reveals
the raw key once and PostgreSQL retains only its prefix and SHA-256 digest.
Each credential references exactly one RHCL `APIProduct`. Inventory, Payment,
and AI Chat therefore have separate HTTPRoutes, authentication metadata lookups, rate-limit
counters, usage records, and invoice lines even when the same Keycloak subject
subscribes to both. The external API-key and JWT hostnames are shared; product
paths (`/inventory`, `/payments`, and `/v1/chat/completions`) select the
independently governed route. AI Chat terminates at a small mesh-injected
facade; the KServe predictor remains cluster-internal. The facade constrains
non-streaming requests, invokes vLLM, and records its prompt plus completion
token counts as the subscription's native billable units. The model namespace
is enrolled in the same Red Hat OpenShift Service Mesh revision. Red Hat's
documented KServe sidecar and probe-rewrite annotations inject the predictor,
and an explicit `ISTIO_MUTUAL` destination rule plus namespace-wide `STRICT`
peer authentication protect the facade-to-model hop.

The control plane discovers API-key APIProducts dynamically. A product enters
the subscription catalog only when it is `Published` and reports both
`Ready=True` and `OpenAPISpecReady=True`; its available tiers come from the
admitted PlanPolicy. Platform-owned products use central plan defaults. Golden
Path products publish reviewed, product-scoped commercial terms alongside the
same five plan identifiers. Publication validates their types and confirms that
commercial quotas and request rates match the Connectivity Link policies before
the control plane persists them. A product is hidden again if its APIProduct
ceases to be healthy.
Generated services expose their OpenAPI document on dedicated port 8082. A
workload-scoped PeerAuthentication keeps API port 8080 in STRICT mTLS and
exempts only the documentation port for the out-of-mesh Kuadrant portal
controller.

The AI Chat playground runs in the existing developer portal but sends
inference directly to the cluster-admitted API-key or JWT Gateway hostname.
Dedicated method-specific `OPTIONS` HTTPRoutes use anonymous AuthPolicies only
for browser preflight. `POST` remains on the authenticated routes and all
responses, including RHCL denials, receive non-credentialed portable CORS
headers. API keys are retained only in the current browser memory after their
one-time reveal; the playground neither persists them nor sends browser
cookies to an API route.

## Request lifecycle

1. The client presents an API key, JWT, or both to a Gateway API endpoint.
2. `AuthPolicy` verifies the credentials and enriches request context with a
   stable customer and plan identity.
3. An authorization rule verifies API product, operation, and subscription.
4. Request and token rate-limit policies select counters using authenticated
   identity and plan data. AI token counters use the immutable subscription UUID,
   which keeps API usage attributable to a commercial lifecycle and gives a new
   subscription a clean counter without deleting shared Limitador state.
   Request limits protect inference capacity before the
   call; RHCL extracts `usage.total_tokens` after a successful OpenAI-compatible
   response and adds that cost to the subscription's Limitador token counter.
5. The gateway routes the accepted request to a mesh-protected backend.
6. Metrics, structured access logs, and traces share request, customer, and API
   identifiers without exposing credential material.
7. Usage is aggregated asynchronously into billable records. Transactional
   APIs contribute one unit per accepted request; AI Chat contributes the exact
   `usage.total_tokens` returned by vLLM. A narrow,
   read-only entitlement lookup participates in authentication; usage rating,
   invoicing, and other billing work never participate in the synchronous path.

## Live plan upgrade

The initial demonstration will deliberately show a free-plan limit being
exceeded, returning HTTP 429. The administrator changes the subscription plan;
the authoritative metadata or policy is reconciled; subsequent traffic receives
the larger limit without a gateway or application restart. Dashboards and logs
must show both the limit event and the new plan attribution.

For API keys, the RHCL developer-portal controller creates the enforcement
credential. After authentication, Authorino retrieves the current subscription
from the monetization control plane as external metadata. `PlanPolicy` selects
the matching limits from that authoritative plan. A live upgrade updates the
APIKey tier for portal visibility and commits the subscription and audit record
to PostgreSQL; the next metadata lookup observes it without recreating the
gateway or application. Argo CD intentionally ignores only the demo APIKey's
mutable `spec.planTier`; every other field remains self-healing.

For JWTs, Keycloak proves identity and audience but does not own commercial plan
state. Authorino resolves interactive portal tokens by Keycloak user subject
and client-credentials tokens by their `azp` client ID. Both map to a customer
in the control plane and then to that customer's current product subscription.
Consequently, the same PostgreSQL transaction that upgrades an API-key customer
also changes the JWT limit. An already-issued JWT receives the new limit on its
next request; no token refresh or Keycloak, gateway, or API workload rollout
participates in the change. API-key rotation deletes the old operator resources,
marks the stored digest revoked, and recreates the External Secrets and RHCL
resources before a new one-time reveal.

## Billing and subscription lifecycle

The control plane produces a live preview for the current UTC calendar month
from stored `billable_units`. Draft generation persists an invoice and its
subscription line items idempotently for that customer and period. Prices use
integer cents and overage uses integer micro-units rounded only after the
period total is calculated. Drafts are estimates based on the subscription's
current plan; issuing and payment remain asynchronous business workflows.

Commercial included allowance is deliberately distinct from enforcement quota.
Free is a hard-capped tier and therefore cannot accrue paid overage. Pay as you
go includes zero units and charges every accepted native unit—an API request or
an AI token—until its separate
monthly safety cap. Developer and Business also have hard quotas above their
included allowances so production-scale usage can accrue overage without
disabling abuse protection. Requests rejected with HTTP 429 never reach the API
usage exporter and are not billable.

The observability model preserves this boundary. The control plane exports
current-month accepted usage, included allowance, hard quota, overage units,
overage revenue, total projected revenue, and short-window limits as Prometheus
gauges. Limitador counters expose allowed and denied decisions separately for
API-key and JWT policy namespaces. Istio gateway metrics show final HTTP status.
Dashboards may correlate those sources, but only stored accepted usage is an
invoice input. The Connectivity Link operator owns the gateway PodMonitor; the
gateway queries select Envoy port 15090 explicitly so the same proxy counters
are not counted again through the pod's status/metrics endpoint.

The community Grafana Operator manages a single-replica, stateless Grafana
instance. Its datasource authenticates to the OpenShift Thanos Querier with a
dedicated service account granted `cluster-monitoring-view`; the service CA and
bearer token are injected into `GrafanaDatasource` secure fields. A
`GrafanaDashboard` imports the Git-managed dashboard ConfigMap. Grafana storage
is intentionally ephemeral because dashboards and datasources are fully
reconstructed by their custom resources, so the demo requires no additional
PVC or RWX storage.

Grafana delegates browser authentication to a confidential Keycloak client
using Authorization Code flow with PKCE. The `monetization-admin` realm role
maps strictly to Grafana Admin and `monetization-developer` maps to Viewer;
users with neither role are denied. The generated client secret is owned in the
identity namespace and mirrored into observability through a namespace-scoped
External Secrets Kubernetes provider with read access to only that Secret. A
GitOps hook discovers the admitted Keycloak and Grafana origins and injects the
OpenShift router CA, so OAuth callback and back-channel TLS verification remain
portable across clusters. The generated local administrator remains enabled
only as a break-glass path.

Suspension changes the commercial subscription state while retaining issued
credentials. Because every accepted request performs an active-entitlement
lookup, API keys and already-issued JWTs are denied immediately and resume
without regeneration. Cancellation marks the subscription and credential
records revoked before deleting the ExternalSecret, generated Secret, Password
generator, and RHCL `APIKey`. This makes the database denial authoritative even
if Kubernetes cleanup is temporarily delayed.

## Security boundaries

- Git contains secret references and schemas, never secret values.
- API keys are stored as non-reversible hashes when lookup requirements permit.
- Telemetry uses a credential fingerprint or customer identifier, not raw keys.
- Gateway-level policies provide deny-by-default safety; route-level policies
  explicitly open an API product.
- Service Mesh mTLS protects internal calls independently of external client
  authentication.
- RHCL internal mTLS is enabled explicitly for both Authorino and Limitador.
  The Kuadrant operator injects their mesh proxies and enforces mutual TLS for
  the gateway authorization and rate-limit calls.
- Authorino reads Keycloak signing keys from the internal JWKS endpoint, which
  remains stable behind its mesh sidecar, and separately validates the portable
  external issuer claim and API audience on every JWT request.
- Demo and lifecycle automation obtain tokens through the admitted HTTPS
  Keycloak Route, so test tokens carry the same issuer as real portal clients.
- Every product API remains strict-mTLS on its runtime port. A separate
  documentation-only port serves each OpenAPI document to the RHCL Developer
  Portal controller, and an earlier Argo sync-wave hook proves both documents
  are reachable before reconciling their `APIProduct` resources.
- The Gateway API data plane and application sidecars are managed by the same
  project Service Mesh control plane and trust root. Application namespaces
  enforce `STRICT` peer authentication, so accepted gateway-to-workload traffic
  is always mutually authenticated and encrypted.
- The OpenShift Router only provides external edge termination when the Gateway
  Service uses `ClusterIP`; it does not introduce another mesh control plane.
- Portal and administration paths are isolated from public API listeners.

## Build and promotion trust chain

The workload Applications inject Argo CD's resolved commit into their build
hooks. Each hook starts an OpenShift Build for that exact commit and accepts the
output only when the Build records the same revision and publishes a digest.
The digest is snapshotted under `git-<12-character-commit>` before the `demo`
delivery tag rolls the workload. Existing immutable tags are reused on retries,
so a repeated sync does not create a second build or silently replace the
revision artifact.

The promotion verifier independently follows the chain from the Application's
sync revision through Build provenance and ImageStreamTag digest to the
Deployment and every ready application container. The source-build hook is
deleted only after success; failed hooks and Builds remain visible in Argo CD
and OpenShift for diagnosis.

## Deployment ordering

```text
GitOps bootstrap
      |
shared namespaces
      |
OLM subscriptions
      |
integrated registry readiness
      |
operator operands and generated secret contracts
      |
PostgreSQL and Keycloak
      |
Service Mesh and Connectivity Link
      |
observability, applications, gateways, policies
```

Each box after bootstrap is an Argo CD child application. Retry and
`SkipDryRunOnMissingResource` handle the short interval between OLM resolving a
subscription and its CRDs becoming discoverable.

---

[Documentation home](README.md) · [Deploy the platform](deployment.md) · [Run the demo](demo-runbook.md)
