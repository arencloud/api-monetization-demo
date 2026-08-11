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
| Operational and business visualization | Grafana and Kiali |
| Desired state and promotion | OpenShift GitOps |

The browser portal is a public PKCE client in Keycloak. Human administrators
receive the `monetization-admin` realm role, while deterministic automation uses
a separate confidential service client with the same narrow role and a
generated secret. The control-plane service verifies token signature, issuer,
audience, expiry, and role before serving subscription, usage, or plan-change
APIs. Entitlement lookups and usage ingestion listen on a separate internal
port that is not exposed by the portal Route.

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

For JWTs, Keycloak proves the machine identity and audience but does not own
commercial plan state. Authorino maps the verified `azp` client identity to a
customer in the control plane, then resolves that customer's current product
subscription. Consequently, the same PostgreSQL transaction that upgrades an
API-key customer also changes the JWT limit. An already-issued JWT receives the
new limit on its next request; no token refresh or Keycloak, gateway, or API
workload rollout participates in the change.

## Security boundaries

- Git contains secret references and schemas, never secret values.
- API keys are stored as non-reversible hashes when lookup requirements permit.
- Telemetry uses a credential fingerprint or customer identifier, not raw keys.
- Gateway-level policies provide deny-by-default safety; route-level policies
  explicitly open an API product.
- Service Mesh mTLS protects internal calls independently of external client
  authentication.
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
