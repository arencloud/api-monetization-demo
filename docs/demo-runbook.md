# Live demo runbook

## Story and expected outcome

Demo Company starts on the Free Inventory API plan. Connectivity Link accepts a
generated API key, attributes requests to the customer and plan, and enforces ten
requests per minute. A burst reaches HTTP 429. The administrator upgrades the
subscription to Developer; continued API-key and JWT bursts succeed under the
new 1,000/minute limit without restarting the gateway or application and
without refreshing the already-issued JWT.

## Before the presentation

### Select and verify the cluster profile

Use the Recommended profile for a customer-facing presentation. Minimum is a
supported functional floor, not a performance target. Large showcase is the
upper profile for this demo rather than an OpenShift maximum.

| Profile | Control plane | Workers | Required demo headroom before bootstrap | Persistent capacity |
| --- | --- | --- | --- | --- |
| Minimum | 3 × 4 vCPU and 16 GiB | 2 × 8 vCPU and 32 GiB | 10 vCPU and 32 GiB after existing pod requests | 60 GiB, including the registry |
| Recommended | 3 × 4 vCPU and 16 GiB | 3 × 8 vCPU and 32 GiB | 16 vCPU and 48 GiB after existing pod requests | 100 GiB |
| Large showcase | 3 × 8 vCPU and 32 GiB | 3 × 16 vCPU and 64 GiB | 28 vCPU and 96 GiB after existing pod requests | 200 GiB |

Each Minimum control-plane and worker node needs at least a 100-GiB disk. The
Recommended and Large profiles use larger worker disks for image, build, and
model layers. A single-node lab instead needs at least 32 CPUs, 128 GiB RAM,
and 200 GiB disk because Red Hat OpenShift AI sets a higher SNO requirement.
See [Deployment prerequisites and sizing](deployment.md#cluster-sizing) for the
resource rationale, Red Hat references, storage breakdown, and SNO caveats.

Before installing, capture scheduler capacity and current commitments:

```bash
oc get nodes \
  -o 'custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory,EPHEMERAL:.status.allocatable.ephemeral-storage'
oc describe nodes | sed -n '/Allocated resources:/,/Events:/p'
oc adm top nodes
oc get storageclass
oc get pvc -n openshift-image-registry
```

Do not use `oc adm top nodes` alone for this decision. It shows instantaneous
usage, while Kubernetes scheduling uses allocatable capacity and pod requests.
Confirm that an `amd64` worker has room for the 4-vCPU/5-GiB AI serving limit,
that a default dynamic StorageClass exists, and that the integrated registry
has a Bound 50-GiB persistent volume with one replica. RWX storage, a GPU, and a
LoadBalancer provider are not required.

### Readiness sequence

1. Push the exact Git revision that will be deployed. Argo CD injects its resolved
   commit into each in-cluster OpenShift build and retains an immutable revision
   tag for verification.
2. Log in to a fresh OpenShift 4.21 or 4.22 cluster as `cluster-admin`.
3. Confirm the cluster matches one of the profiles above. For a shared cluster,
   subtract existing pod requests from worker allocatable capacity before
   comparing it with the headroom column.
4. Confirm the other prerequisites: Red Hat product entitlements, required
   Operator catalogs, Open Data Hub absent, external image-registry access,
   outbound npm access for the Kuadrant RHDH plugins, and outbound Hugging Face
   model access.
5. Run the complete deployment sequence:

   ```bash
   make validate
   make test
   make preflight
   make bootstrap
   make status
   make promotion-status
   make verify
   ```

6. Confirm the expected catalog and policy resources:

   ```bash
   oc get apiproduct,apikey,planpolicy,authpolicy,ratelimitpolicy \
     -n api-monetization-apps
   oc get gateway -n api-monetization-gateway
   oc get route -n api-monetization-gateway
   ```

   `make verify` prints the cluster-generated API-key, JWT, and portal URLs.
   Confirm that both use the current cluster's ingress domain. The APIProduct
   **Try it out** view must show the same API-key endpoint rather than the
   OpenShift console URL.

7. Reset the commercial state, then allow one minute for any old rate-limit
   counters to expire:

   ```bash
   make reset-demo
   ```

## Presentation sequence

For a fully automated presentation with readiness checks, real rate-limit
windows, billing evidence, URLs, and final state restoration, run:

```bash
make showcase
```

The command deliberately waits at least 60 seconds before and after the traffic
scenario because it proves the real Connectivity Link counters instead of
deleting or bypassing them. It finishes with a PASS/FAIL table and leaves Demo
Company on Free, ready for another run. Accepted usage, invoices, and audit
history remain stored as evidence. The sections below describe the same story
for a manually paced presentation.

### 1. Establish the baseline

Show the `Inventory API` and `Payment API` under **Connectivity Link → API Products** in the
OpenShift console. Explain that `APIProduct`, `PlanPolicy`, and `APIKey` are
operator-managed platform APIs rather than records hidden inside a monolithic
API-management product.

The **Connectivity Link** and **GitOps** console entries are enabled by GitOps
after their Operators install the corresponding console plugins.

Open the unified developer experience and print its generated test identities:

```bash
make hub
```

Sign in as `demo-developer`, open **APIs**, and confirm that six entries were
synchronized from the live `APIProduct` resources. Inventory,
Payment, and AI Chat each have an **API Key** entry and a **Keycloak JWT** entry
whose Authentication column is **OIDC**. Open a JWT entry and confirm its OIDC
tab publishes the cluster's Keycloak token endpoint. JWT entries do not create
an `APIKey`: obtain a short-lived bearer token from Keycloak instead. Published
entries show **Production** and **Subscription required** until this developer
subscribes to the logical product. The locked rows are greyed and their product
detail links remain unavailable, while the subscription action stays active.
Confirm unsubscribed production entries are greyed and cannot open their
catalog details. This view is subject-scoped; it is not only a visual copy of
the shared catalog.
Open **Billing**, subscribe to a plan, wait
for the operator-backed credential to become ready, and reveal it once. Return
to **APIs** and confirm both the API-key and JWT presentations show
**Subscribed**, return to their normal styling, and expose their detail links.
Cancellation immediately restores the grey subscription-required state and
denies both credential forms. API-key reveal and rotation, Keycloak token
issuance, and credential status remain on the corresponding **Billing**
subscription. No raw API-key creation or approval page is exposed.
Sign in as `demo-admin` to show the cross-customer commercial view. The custom portal
remains available as a rollback path and for the AI playground. Open **Billing**
in RHDH to show the permission-scoped subscription, accepted usage,
AI token totals, projected revenue, and persisted invoices. A developer sees
only the PostgreSQL customer mapped to their Keycloak subject; `demo-admin`
sees the cross-customer view. The technical `/kuadrant/api-products` route is
retained without a navigation entry for owners who need to inspect effective
request and token policies; it is read-only for credentials.

Show the running topology:

```bash
oc get pods -n api-monetization-apps
oc get pods -n kuadrant-system
oc get pods -n api-monetization-identity
oc get pods -n api-monetization-observability
```

### 2. Execute the deterministic scenario

```bash
make demo
```

The showcase first proves simultaneous Inventory Free and Payment Developer
subscriptions with independent API keys, limits, and usage attribution. Its
Inventory-only live-upgrade stage then demonstrates, in order:

1. The gateway Argo CD Application is Synced and the exact JWT authentication
   and rate-limit policy generations are Enforced.
2. A request without credentials returns HTTP 401.
3. A Keycloak machine JWT is issued for Demo Company's mapped identity.
4. Valid Free-plan API-key traffic returns HTTP 200, then exceeds ten
   requests/minute and returns HTTP 429.
5. The same Free subscription is resolved for the JWT; its burst also reaches
   HTTP 429 through a separate `AuthPolicy` and `RateLimitPolicy`.
6. The control plane changes Demo Company's single subscription to Developer.
7. Twelve additional API-key requests all return HTTP 200 without a rollout,
   proving that the user can continue immediately under the Developer limit.
8. Twelve requests using the exact JWT issued before the upgrade all return
   HTTP 200, proving that plan state is live and is not embedded in the token.

The Free tier intentionally has no billable overage: its 1,000 included monthly
requests equal its 1,000-request hard quota, and its 10/minute rate limit rejects
bursts before the backend. To demonstrate real usage-based charging, run:

```bash
make metered-demo
```

This changes Demo Company to Pay as you go, where zero requests are included,
accepted traffic costs €0.01/request, the safety limits are 100/minute and
10,000/month, and five genuine Inventory API calls produce billable usage and a
stored draft invoice. The script leaves the result visible in the administrator
portal. HTTP 429 attempts remain non-billable because Connectivity Link rejects
them before the Inventory API. Return to the baseline with `make reset-demo`.

For rehearsals, the automated command accepts these bounded overrides:

```bash
SHOWCASE_COUNTER_WAIT_SECONDS=65 \
SHOWCASE_METRICS_WAIT_SECONDS=30 \
SHOWCASE_METERED_REQUESTS=5 \
make showcase
```

The counter wait cannot be configured below 60 seconds because doing so would
make the Free-plan rate-limit proof nondeterministic.

Keep this rollout watch visible during the upgrade if desired; no revision or
pod restart should appear:

```bash
oc get pods -n api-monetization-apps --watch
```

### 3. Prove policy and commercial state

Print the portal address and generated developer/administrator logins, then open
it in a browser:

```bash
make portal
```

Run `make portal` to print both generated identities. Sign in as
`demo-developer`, choose Inventory, Payment, or AI Chat and a plan, and select **Subscribe and
generate key**. External Secrets creates the key material and RHCL approves the
APIKey. Select **Reveal API key once**, copy it, and call the displayed endpoint.
The key is not displayed on a later login. Select **Regenerate API key** to
revoke it and obtain a replacement through the same operator-backed flow.
Select **Get Keycloak token** to display a short-lived JWT and call the separate
JWT endpoint with `Authorization: Bearer`. Both credentials resolve this
developer's subscription and current plan. Change the plan from **My
subscription** and show that the new limit applies immediately.

Switch the product selector and subscribe to the other API on a different plan.
The portal retains both subscriptions and exposes a different API key while the
same Keycloak identity works on both JWT paths. The following deterministic
test proves this without changing the browser account:

```bash
make multi-product-test
make ai-monetization-test
make ai-demo
```

For AI Chat, the API-key and JWT routes both expose
`POST /v1/chat/completions`. Connectivity Link enforces request authentication,
entitlement, a requests-per-minute safety limit, and a plan-specific monthly
token quota. RHCL `TokenRateLimitPolicy` extracts the OpenAI-compatible
`usage.total_tokens` response field and updates Limitador after inference. The response header
`X-Monetization-Billable-Units` equals vLLM's `usage.total_tokens`; the portal,
invoice preview, Prometheus metrics, and Grafana dashboard use that stored token
total rather than counting the completion as one request.

Select an active AI Chat subscription in the portal to open **AI Chat
playground**. Choose **Keycloak JWT** or reveal the AI API key once and choose
**API key**, enter a prompt, and select **Send Chat**. The browser calls the
admitted Gateway API hostname, not the internal model service. The result shows
the completion, prompt/completion/total token split, billing header, stored
tokens, remaining plan allowance, above-allowance tokens, and projected AI
revenue.

For a repeatable live quota story, use **Demonstrate Free HTTP 429** on a new
Free AI subscription, then change the plan to Developer and send another chat.
The large first request is accepted and its actual response token total is
added by RHCL after inference; the following request is rejected with HTTP 429.
The plan change immediately admits the next request. For an unattended proof of
both credential paths and automatic cleanup, run:

```bash
make ai-demo
```

The command discovers ingress hosts and certificates from the cluster, uses a
dedicated Keycloak automation identity, and cancels its test subscription on
success or interruption. Each resubscription receives a new UUID and therefore
a fresh RHCL token-counter identity. It does not delete shared Limitador data or
contain a cluster-specific hostname.

The Gateway-to-facade and facade-to-KServe predictor hops both use strict Red
Hat OpenShift Service Mesh mTLS. The predictor uses the KServe sidecar injection
and application-probe rewrite annotations documented by Red Hat.

Generate the current draft under **Billing and invoices**. The persisted draft
shows the plan base charge, stored billable units, allowance, overage, and total
using integer monetary units. Show **Lifecycle history** for subscription,
plan, and credential events. An administrator can select **Suspend access** to
deny both credential paths without deleting them, then **Resume access** to
restore them. Developer cancellation is terminal for that subscription and
removes the operator-managed API-key resources; a later subscription creates a
new credential.

Before presenting the browser lifecycle, the same behavior can be checked
without touching either demo account:

```bash
make lifecycle-test
```

The automation proves that active API-key and JWT traffic returns `200`, a
suspended subscription returns an authorization denial, resume restores the
same credentials, cancellation revokes access and removes operator-managed
credential resources, and resubscription generates a different API key.

Sign in as `demo-admin` to show the commercial dashboard. It displays the
subscription, current rate limit, stored usage, projected revenue, and plan
selector. Apply an administrative plan change and explain that the protected
API writes commercial state and reconciles the RHCL APIKey tier without
restarting a workload.

The same state can be inspected from the command line with the scoped
automation identity:

```bash
oc get apikey demo-inventory-key -n api-monetization-apps \
  -o jsonpath='{.spec.planTier}{"\n"}'

oc port-forward -n api-monetization-data service/monetization-control 18080:8080
control_token=$(./scripts/control-token.sh)
curl --silent --header "Authorization: Bearer $control_token" \
  http://127.0.0.1:18080/api/subscriptions | jq .
```

### 4. Show observability evidence

Print the live business and enforcement summary from OpenShift monitoring:

```bash
make observe
make grafana
```

The output separates current-month accepted billable usage and revenue from
last-hour Connectivity Link decisions and gateway HTTP status. API-key and JWT
decisions are attributed using their distinct Limitador namespaces. This is the
fastest terminal presentation path. `make grafana` prints the automatically
provisioned Grafana URL and both SSO test identities. Sign in as `demo-admin`
for Grafana Admin access or `demo-developer` for read-only Viewer access.
Administrators can also open it from the monetization portal's **Platform
views → Business dashboard** link; an existing Keycloak session provides SSO.
The command also prints a generated local administrator and explicit
`disableAutoLogin` URL for break-glass recovery.

Accepted traffic and plan attribution:

```promql
sum by (customer, plan) (
  increase(api_requests_total{service="inventory-api"}[5m])
)
```

Structured request logs include request ID, W3C `traceparent`, customer, plan,
status, and duration:

```bash
oc logs -n api-monetization-apps deployment/inventory-api -c inventory-api --tail=30
```

Open the Tempo Jaeger UI route:

```bash
oc get route tempo-api-monetization-jaegerui \
  -n api-monetization-observability -o jsonpath='https://{.spec.host}{"\n"}'
```

The Grafana Operator imports the dashboard JSON from the
`api-monetization-grafana-dashboard` ConfigMap through the
`GrafanaDashboard/api-monetization` resource. It contains current-month
accepted usage, commercial allowance and hard quota, billable overage and
revenue, API-key/JWT allow and limit decisions, gateway response codes, latency,
and live plan-change counters. Inspect the declarative import with:

```bash
oc get configmap api-monetization-grafana-dashboard \
  -n api-monetization-observability \
  -o go-template='{{index .data "api-monetization.json"}}'
oc get grafanas.grafana.integreatly.org,\
grafanadatasources.grafana.integreatly.org,\
grafanadashboards.grafana.integreatly.org \
  -n api-monetization-observability
```

## Business message

Connectivity Link owns synchronous enforcement, while commercial state and
billing remain independently evolvable. Plan changes are data changes, not
gateway deployments. API workloads do not contain authentication, subscription,
or rate-limit code, and the same architecture supports API keys and enterprise
OIDC simultaneously.

## Reset

```bash
make reset-demo
```

The reset changes the shared API-key and Keycloak JWT subscription
back to Free. Limitador counters are intentionally not deleted; wait for the
one-minute demo window before repeating the burst.
