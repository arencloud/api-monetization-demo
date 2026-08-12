# Architecture

## System context

The platform separates the customer-facing product lifecycle from request-time
enforcement. This prevents the gateway from becoming a billing database and
allows commercial workflows to evolve without changing API workloads.

```text
                              CONTROL PLANE
 RHCL Console Portal -> APIProduct/APIKey -> generated credential metadata
 Monetization Portal -> Keycloak login -> subscription / usage / live upgrade
         |                        |                         |
         +------------------------+-------------------------+
                              |
Internet -> OpenShift Route -> Gateway API -> RHCL policies -> Service Mesh -> OpenShift APIs
                              |
                              v
          Prometheus / structured logs / Tempo -> billing dashboard
                               DATA PLANE
```

The OpenShift Route path is always available. A cluster with a functioning
Service LoadBalancer provider additionally exposes the same Gateway through its
assigned external address; the request-time policy path is unchanged.

## Responsibilities

| Capability | Owner |
| --- | --- |
| API catalog, documentation, API-key requests | RHCL OpenShift console plugin |
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

## Request lifecycle

1. The client presents an API key, JWT, or both to a Gateway API endpoint.
2. `AuthPolicy` verifies the credentials and enriches request context with a
   stable customer and plan identity.
3. An authorization rule verifies API product, operation, and subscription.
4. Rate-limit policy selects counters using authenticated identity/plan data.
5. The gateway routes the accepted request to a mesh-protected backend.
6. Metrics, structured access logs, and traces share request, customer, and API
   identifiers without exposing credential material.
7. Usage is aggregated asynchronously into billable records. A narrow,
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
go includes zero units and charges every accepted request until its separate
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
- The Inventory API remains strict-mTLS on its runtime port. A separate
  documentation-only port serves the OpenAPI document to the RHCL Developer
  Portal controller, and an earlier Argo sync-wave hook proves that document is
  reachable before reconciling the `APIProduct`.
- The Gateway API data plane and application sidecars are managed by the same
  project Service Mesh control plane and trust root. Application namespaces
  enforce `STRICT` peer authentication, so accepted gateway-to-workload traffic
  is always mutually authenticated and encrypted.
- The OpenShift Router only provides external edge termination when the Gateway
  Service uses `ClusterIP`; it does not introduce another mesh control plane.
- Portal and administration paths are isolated from public API listeners.

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
