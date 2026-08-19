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
| `applications/` | Inventory, Payment, and monetization control-plane source/builds |
| `golden-paths/` | RHDH Software Templates and standalone API project skeletons for API owners |
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
| Red Hat Developer Hub | 1.10 z-stream (`fast-1.10`) |
| Red Hat OpenShift Dev Spaces | Latest `stable` channel z-stream |
| Kuadrant Developer Hub plugin | 0.4.0, integrity-pinned |
| Effective-policy catalog plugin | 0.1.7, source-controlled local TGZ |
| Monetization backend plugin | 0.1.5, source-controlled local TGZ |
| Red Hat OpenShift GitOps | Latest catalog channel, automatic upgrades |
| Red Hat OpenShift AI | 3.4 stable channel, 3.4.3 starting CSV |
| External Secrets Operator for Red Hat OpenShift | 1.2 |
| CloudNativePG certified Operator | 1.30 |
| Developer Hub database | PostgreSQL 17.11, multi-architecture digest pin |
| Red Hat build of OpenTelemetry Operator | stable, 0.152.0-2 starting CSV |
| Tempo Operator | stable, 0.21.0-3 starting CSV |
| Grafana Operator | v5, 5.24.0 starting CSV |
| Application build toolchain | Red Hat UBI 9 Go Toolset 1.26.5 |

The cluster must have subscriptions/entitlements for the Red Hat products. Run
`make preflight` before making any cluster changes.

The optional CPU AI milestone also requires outbound access to Hugging Face.
Its pinned Qwen2.5 0.5B model is downloaded when the serving Pod starts. No GPU,
GPU Operator, RWX volume, or LoadBalancer provider is required.

The Developer Hub Pod also requires outbound access to `registry.npmjs.org` on
first start so its pinned Kuadrant dynamic plugin packages can be installed.

Because the current profile includes OpenShift AI, the minimum multi-node
cluster has three 4-vCPU/16-GiB control-plane nodes and two schedulable
8-vCPU/32-GiB workers. For a reliable live presentation, use three
8-vCPU/32-GiB workers and at least 100 GiB of provisionable persistent
capacity. The registry consumes a one-replica 50-GiB persistent volume; the
subscription and Keycloak PostgreSQL clusters consume 2 GiB each, and the
Developer Hub PostgreSQL cluster consumes 5 GiB, and the first Dev Spaces user
workspace consumes a default 10-GiB persistent volume. See
[the deployment sizing profiles](docs/deployment.md#cluster-sizing) for
Minimum, Recommended, Large showcase, and single-node requirements, and use
[the runbook resource gate](docs/demo-runbook.md#select-and-verify-the-cluster-profile)
before bootstrap.

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
make verify
make promotion-status
```

`make bootstrap` is the only imperative installation step. It installs the
OpenShift GitOps Operator, waits for the default Argo CD instance, grants its
dedicated application controller the cluster access required to reconcile this
cluster-configuration repository, and applies the root application. Argo CD
owns everything below that root.

Application source is built inside OpenShift from the exact commit reconciled
by Argo CD. Successful outputs receive immutable `git-<commit>` ImageStreamTags;
`make promotion-status` verifies the Argo revision, OpenShift Build, delivery
tag, Deployment digest, and running Pods agree.

The root application points to this repository's canonical GitHub URL and the
selected delivery branch. Before bootstrapping another branch, align
`bootstrap/root/application.yaml`, the generated source in
`gitops/applications/kustomization.yaml`, and every application `BuildConfig`
Git ref. Restore all of them to `main` before merging a feature branch.

Detailed prerequisites, verification, and recovery steps are in
[the deployment guide](docs/deployment.md).

## Implemented solution

The repository now contains the complete single-cluster demo path: operator and
GitOps bootstrap, integrated-registry readiness validation, OpenShift Routes,
Service Mesh, Connectivity Link, the enabled GitOps and RHCL console plugins,
the RHCL developer catalog,
External Secrets-generated API keys, Keycloak JWT clients, Free/Developer/Business/
Enterprise plan policies plus a real Pay-as-you-go metered tier, independently
monetized Inventory, Payment, and AI Chat APIs, a PostgreSQL-backed subscription
control plane, live plan changes, Prometheus metrics, an operator-managed
Grafana instance and dashboard, structured logs, and an OpenTelemetry-to-Tempo
trace pipeline.

Red Hat Developer Hub is installed through its Operator as the strategic
developer experience. The integrity-pinned Kuadrant frontend and backend
plugins synchronize six RHCL `APIProduct` resources into the catalog: an
API-key and a Keycloak OIDC/JWT presentation of each Inventory, Payment, and AI
Chat API. They provide read-only product discovery and OIDC metadata. GitOps
discovers the admitted Keycloak issuer
and installs the OpenShift router CA into the RHCL OIDC components, so the same
catalog works on a fresh cluster with a different applications domain.
The default RHDH Lightspeed flavour is disabled because the solution already
contains its independently governed OpenShift AI chat product.

Members of the `api-owners` group also receive two governed
[Golden Paths](docs/golden-paths.md). The standard path creates a contract-first
Go API and the integration path creates a Red Hat Camel Quarkus API with a
Kaoto-editable mapping route. Each scaffolder run creates and registers a
dedicated GitHub repository containing application source, OpenAPI, tests,
OpenShift builds, Service Mesh configuration, Gateway API routes, RHCL
authentication and plan resources, APIProducts, TechDocs, and a restricted
Argo CD bootstrap Application. New products start in Draft. After review, the
owner publishes from the Component Overview: Developer Hub validates the
repository, applies cluster-specific gateway and identity settings through the
restricted AppProject, and the control plane adds the product to consumer
subscriptions only after its APIProduct and OpenAPI contract are ready.

Developer Hub delegates login to the existing Red Hat build of Keycloak realm.
Its source-built login theme uses the Red Hat PatternFly visual language, while
RHDH retains its native application shell with API Monetization branding.
Self-registration is enabled for consumers: every new account enters the
`api-consumers` group and receives the developer realm role used by the
subscription APIs. Owner access is never self-assigned. A consumer requests it
from **Subscriptions & Access**, an administrator reviews the request there,
and an approval moves that identity to `api-owners`. Keycloak groups map to the
Kuadrant consumer, owner, and administrator roles.
The source-controlled RHDH extension resolves effective `PlanPolicy`, direct
`RateLimitPolicy`, and `TokenRateLimitPolicy` resources and adds a subscription view
for subscriptions, accepted request/token usage, projected revenue, and
invoices. Both the Kuadrant API Products view and Developer Hub's APIs explorer
treat published products as production APIs and show whether the signed-in
consumer has an active subscription. The **Subscriptions & Access** page provides
consumer-scoped subscribe, plan-change, cancellation, one-time API-key
reveal/rotation, and Keycloak JWT workflows. Raw Kuadrant credential and
approval pages are deliberately absent: the subscription control plane is the
only credential writer. Its backend applies RHDH permissions before
forwarding the signed-in user's Keycloak token, while the existing control
plane independently checks the role and maps the token subject to exactly one
customer. Owner requests and review decisions are retained as an auditable
PostgreSQL workflow. A dedicated least-privilege Keycloak service identity can
change user/group membership; the RHDH organization provider remains
read-only. PostgreSQL remains the sole commercial system of record. The
existing portal remains deployed as a rollback path and for the AI playground.

The current development milestone adds an Operator-managed OpenShift AI 3.4
foundation, KServe, and a pinned Qwen2.5 0.5B Instruct model served by Red Hat's
vLLM CPU x86 runtime. A mesh-injected facade keeps the model internal, exposes
its OpenAI-compatible chat operation through Connectivity Link, and stores the
vLLM-reported prompt plus completion tokens as native billable units. RHCL
`TokenRateLimitPolicy` extracts the same OpenAI-compatible
`usage.total_tokens` response field and enforces plan-specific monthly token
quotas in Limitador; the ordinary request policy remains as a separate
requests-per-minute abuse guard.

The monetization portal is exposed through a portable OpenShift Route and uses
Red Hat build of Keycloak Authorization Code flow with PKCE. Its subscription,
usage, and upgrade APIs require the `monetization-admin` realm role; internal
entitlement and usage ingestion use a separate, non-routed service port.

For AI Chat, the developer portal includes a browser playground that calls the
cluster-admitted Gateway API endpoints directly. A developer can select the
one-time-revealed API key or their existing Keycloak access token, submit a
prompt, inspect the model response and exact prompt/completion/total-token
counts, and compare consumed, remaining, overage, and projected-revenue data.
Only the `OPTIONS` preflight routes permit anonymous access. Actual inference
remains protected by RHCL authentication, entitlement, request limits, and
token limits. Portable CORS rules do not use cookies and therefore require no
cluster-specific portal hostname.

Developers authenticate with the separate `monetization-developer` role. They
can browse the multi-product API catalog, but a production API rejects their
API-key and JWT requests until they subscribe to its logical commercial
product. Both authentication presentations share that subscription. Developers
choose an independent plan for each product, create their own PostgreSQL
customer and subscriptions in RHDH, and request product-scoped API keys or a
short-lived Keycloak JWT. The
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
make showcase
```

`make showcase` is the complete presentation path. It verifies the deployed
platform, proves simultaneous Inventory and Payment subscriptions, proves AI
Chat with both credential types and real token attribution, establishes
a clean Free-plan window, proves API-key and JWT rate
limiting plus the live Developer upgrade, creates real Pay-as-you-go usage and
a draft invoice, prints Prometheus evidence and all UI/API URLs, and restores
Demo Company to a reusable Free state. It prints a stage-by-stage PASS/FAIL
summary and also restores the plan after interruption. Stored accepted usage,
invoice history, and audit records remain as intentional business evidence.

The individual scenarios remain available for focused development and manual
presentations:

```bash
make lifecycle-test
make multi-product-test
make ai-model-test
make ai-monetization-test
make ai-demo
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

`make multi-product-test` creates simultaneous Inventory Free and Payment
Developer subscriptions for the automation identity, proves both API-key and
JWT paths, confirms per-product usage attribution, and cancels its test
subscriptions afterward. The browser developer and Demo Company remain
unchanged.

`make ai-monetization-test` creates a dedicated Developer AI Chat subscription,
proves API-key and Keycloak JWT inference through Connectivity Link, verifies
that the billed units exactly match vLLM's `usage.total_tokens`, proves both
RHCL/Limitador namespaces advance by those response tokens plus the independent
request-guard hit, waits for the asynchronous PostgreSQL attribution, and
cancels its automation subscription.
Deployment verification also requires both AI `TokenRateLimitPolicy` objects
to be Enforced and the facade-to-KServe hop to use strict Service Mesh mTLS.

`make ai-demo` is the deterministic AI business presentation. It creates a new
Free AI Chat subscription, proves browser preflight, sends a model request whose
reported token cost crosses the Free allowance, observes HTTP 429 on the next
request for both API-key and already-issued JWT paths, upgrades that same
subscription to Developer, and immediately continues with both credentials.
It then waits for PostgreSQL attribution and prints consumed tokens, remaining
Developer allowance, and projected revenue. Its automation identity is
cancelled on success or interruption. Token counters use the immutable
subscription UUID, so the next run starts with a new counter without requiring
privileged Limitador cleanup or relying on a fixed cluster hostname.

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
