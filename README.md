# API Monetization on Red Hat OpenShift

This repository contains the declarative foundation for a reproducible API
monetization demonstration built around Red Hat Connectivity Link (RHCL).
RHCL is the policy enforcement point; subscription management, usage
aggregation, and billing remain independent services.

## Target experience

A developer subscribes to an API plan, receives credentials, and calls an API
through a Gateway API gateway. The request is authenticated, authorized,
rate-limited, observed, and attributed to a subscription. During the demo an
administrator upgrades the subscription and the new limits take effect without
restarting the gateway or application.

```text
Internet -> OpenShift Route -> Gateway API -> Connectivity Link -> Service Mesh -> APIs
                                 |              |                 |
                              TLS/DNS      Auth and limits   mTLS and traces
                                 +--------------+-----------------+
                                   |
                    Metrics, logs, traces, usage, billing
```

OpenShift Routes always provide the portable entry path shown above. When
MetalLB, a cloud integration, or another Service LoadBalancer provider assigns
an external address, the Gateway also retains that direct LoadBalancer entry.
The API hostnames are generated beneath the cluster ingress domain and are
printed by `make verify`; no external DNS setup is required for the baseline.

See [the architecture](docs/architecture.md) for component responsibilities and
trust boundaries.

## Deployment principles

- OpenShift GitOps is the only steady-state deployment mechanism.
- Red Hat products and other operator-capable platform services are installed
  with OLM Operators.
- Operator subscriptions and their operands are separate GitOps applications so
  CRDs can become available before custom resources are reconciled.
- No credentials are committed. Secrets must be supplied by an approved secret
  manager or created as a documented bootstrap prerequisite.
- Compatibility channels are deliberately selected as a tested set; upgrades
  are reviewed as a set rather than component by component.
- Every layer is idempotent and can be rendered locally before it reaches a
  cluster.

## Repository layout

| Path | Purpose |
| --- | --- |
| `bootstrap/` | One-time installation of OpenShift GitOps and the root application |
| `gitops/applications/` | App-of-apps definitions and reconciliation ordering |
| `operators/` | OLM subscriptions and operator groups |
| `platform/` | Operator-managed platform operands and shared namespaces |
| `applications/` | Inventory API and monetization control-plane source/builds |
| `policies/` | Gateway, authentication, authorization, and limit policies |
| `dashboards/` | Business and platform observability assets |
| `environments/` | Environment-specific composition and configuration |
| `scripts/` | Bootstrap, preflight, and validation automation |
| `docs/` | Architecture, operations, decisions, and demo runbooks |

## Supported initial profile

The first profile follows the RHCL 1.4 support matrix:

| Component | Selected compatibility lane |
| --- | --- |
| OpenShift Container Platform | 4.21–4.22 |
| Red Hat Connectivity Link | 1.4 stable channel, 1.4.1 or later |
| Red Hat OpenShift Service Mesh | 3.4 |
| cert-manager Operator for Red Hat OpenShift | 1.19 |
| Red Hat build of Keycloak | 26.6 |
| Red Hat OpenShift GitOps | 1.21 |
| External Secrets Operator for Red Hat OpenShift | 1.2 |
| CloudNativePG certified Operator | 1.30 |
| Red Hat build of OpenTelemetry Operator | stable, 0.152.0-2 starting CSV |
| Tempo Operator | stable, 0.21.0-3 starting CSV |
| Grafana Operator | v5, 5.24.0 starting CSV |
| Application build toolchain | Red Hat UBI 9 Go Toolset 1.26.5 |

The cluster must have subscriptions/entitlements for the Red Hat products. Run
`make preflight` before making any cluster changes.

## Quick start

Prerequisites: `oc`, cluster-admin access, the Red Hat, certified, and community
operator catalogs, and a cluster matching the profile above. Grafana Operator
is community-supported; Red Hat product components continue to use their Red
Hat Operators.

```bash
make validate
make test
make preflight
make bootstrap
```

`make bootstrap` is the only imperative installation step. It installs the
OpenShift GitOps Operator, waits for the default Argo CD instance, grants its
dedicated application controller the cluster access required to reconcile this
cluster-configuration repository, and applies the root application. Argo CD
owns everything below that root.

The root application currently points to this repository's canonical GitHub
URL and the `main` branch. Before bootstrapping a fork or another branch, change
the source in `bootstrap/root/application.yaml` and the two source literals in
`gitops/applications/kustomization.yaml`.

Detailed prerequisites, verification, and recovery steps are in
[the deployment guide](docs/deployment.md).

## Implemented solution

The repository now contains the complete single-cluster demo path: operator and
GitOps bootstrap, integrated-registry readiness validation, OpenShift Routes,
Service Mesh, Connectivity Link, the enabled GitOps and RHCL console plugins,
the RHCL developer catalog,
External Secrets-generated API keys, Keycloak JWT clients, Free/Developer/Business/
Enterprise plan policies plus a real Pay-as-you-go metered tier, an Inventory
API, a PostgreSQL-backed subscription
control plane, live plan changes, Prometheus metrics, an operator-managed
Grafana instance and dashboard, structured logs, and an OpenTelemetry-to-Tempo
trace pipeline.

The monetization portal is exposed through a portable OpenShift Route and uses
Red Hat build of Keycloak Authorization Code flow with PKCE. Its subscription,
usage, and upgrade APIs require the `monetization-admin` realm role; internal
entitlement and usage ingestion use a separate, non-routed service port.

Developers authenticate with the separate `monetization-developer` role. They
can browse the API catalog, choose a plan, create their own PostgreSQL customer
and subscription, and request an API key or short-lived Keycloak JWT. The
control plane creates an External Secrets Password generator and ExternalSecret
before submitting the RHCL `APIKey`; the raw credential is displayed once and
only its digest is retained in the commercial datastore. Developers can rotate
the API key from the portal, which revokes the previous key and provisions a
new operator-managed credential. Interactive JWTs resolve the same subscription
and current plan by the Keycloak user subject.

The portal also calculates current-calendar-month billing previews from stored
billable units and persists refreshable draft invoices with line items. A
developer can inspect invoice and lifecycle history or cancel a subscription;
cancellation removes its operator-managed API key and immediately denies both
API-key and already-issued JWT entitlement. Administrators can suspend and
resume a subscription without regenerating credentials.

The deterministic scenario issues an API key and a Keycloak JWT for the same
customer subscription, drives both through the Free limit, and performs one
live Free-to-Developer upgrade. Both credentials immediately receive the new
limit, including the already-issued JWT, because commercial state is resolved
from PostgreSQL rather than embedded in the signed token.

After deployment and verification, run the deterministic scenario:

```bash
make lifecycle-test
make demo
make metered-demo
make observe
make grafana
make reset-demo
make portal
```

`make lifecycle-test` uses dedicated Keycloak automation identities to prove
active API-key and JWT access, administrative suspension and resume, developer
cancellation, operator-resource cleanup, and clean resubscription. It leaves
the browser `demo-developer` and the deterministic `demo-company` scenario
unchanged and returns its own automation subscription to a cancelled state.

`make metered-demo` changes Demo Company to Pay as you go, sends five real
accepted requests through the OpenShift Route and Connectivity Link, waits for
asynchronous usage attribution, and persists a draft invoice. Pay as you go has
no included requests, a 10,000-request monthly safety cap, a 100/minute rate
limit, and a €0.01 charge per accepted request. HTTP 429 responses are rejected
before the Inventory API and are therefore never counted or billed. Run
`make reset-demo` afterward to return Demo Company to Free.

`make observe` queries OpenShift user-workload monitoring and prints the live
commercial and policy evidence directly from Thanos. It
shows PostgreSQL-backed accepted usage, overage and revenue; Limitador decisions
split between API-key and JWT; and Istio gateway responses by HTTP status. The
operator-managed Grafana instance presents the same separation visually. It
uses the same Keycloak identities as the portal: `demo-admin` receives the
Grafana Admin role and `demo-developer` receives Viewer. Run `make grafana` to
print its admitted HTTPS URL, SSO credentials, and the generated local
break-glass login. In particular, HTTP 429 traffic remains observable while
never being included in billing.

The portable demo profile intentionally requires neither a LoadBalancer
provider nor production infrastructure. It uses `ClusterIP` plus admitted
OpenShift Routes when MetalLB or a cloud load balancer is unavailable. External
DNS/TLS, object storage, PostgreSQL HA/backups, and disaster recovery belong in
a separate environment-specific production overlay and are not baseline
installation prerequisites.

See [the live demo runbook](docs/demo-runbook.md) before presenting it.
