# Live demo runbook

## Story and expected outcome

Demo Company starts on the Free Inventory API plan. Connectivity Link accepts a
generated API key, attributes requests to the customer and plan, and enforces ten
requests per minute. A burst reaches HTTP 429. The administrator upgrades the
subscription to Developer; a continued burst succeeds under the new
1,000/minute limit without restarting the gateway or application. The same
Free-to-Developer transition is then applied to a Keycloak machine client. Its
existing JWT remains Free, while a refreshed token carries the Developer claim
and immediately receives the larger limit.

## Before the presentation

1. Push the exact Git revision that will be deployed. In-cluster OpenShift builds
   and Argo CD both read the configured `main` revision.
2. Log in to a fresh OpenShift 4.21 or 4.22 cluster as `cluster-admin`.
3. Confirm at least 12 GiB of allocatable memory remains for the demo profile.
4. Run the complete deployment sequence:

   ```bash
   make validate
   make test
   make preflight
   make bootstrap
   make status
   make verify
   ```

5. Confirm the expected catalog and policy resources:

   ```bash
   oc get apiproduct,apikey,planpolicy,authpolicy,ratelimitpolicy \
     -n api-monetization-apps
   oc get gateway -n api-monetization-gateway
   oc get route -n api-monetization-gateway
   ```

   `make verify` prints the cluster-generated API-key and JWT endpoint URLs.
   Confirm that both use the current cluster's ingress domain. The APIProduct
   **Try it out** view must show the same API-key endpoint rather than the
   OpenShift console URL.

6. Reset the commercial state, then allow one minute for any old rate-limit
   counters to expire:

   ```bash
   make reset-demo
   ```

## Presentation sequence

### 1. Establish the baseline

Show the `Inventory API` under **Connectivity Link → API Products** in the
OpenShift console. Explain that `APIProduct`, `PlanPolicy`, and `APIKey` are
operator-managed platform APIs rather than records hidden inside a monolithic
API-management product.

The **Connectivity Link** and **GitOps** console entries are enabled by GitOps
after their Operators install the corresponding console plugins.

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

The script demonstrates, in order:

1. A request without credentials returns HTTP 401.
2. Valid Free-plan API-key traffic returns HTTP 200.
3. A burst exceeds ten requests/minute and returns HTTP 429.
4. The control plane changes Demo Company to Developer.
5. Twelve additional API-key requests all return HTTP 200 without a rollout,
   proving that the user can continue immediately under the Developer limit.
6. A Free JWT from `demo-free-client` reaches its ten-request limit and returns
   HTTP 429 through a separate `AuthPolicy` and `RateLimitPolicy`.
7. The Keycloak plan mapper changes from Free to Developer without a rollout.
8. The existing JWT remains rate-limited because signed token claims are
   immutable; a refreshed JWT contains `plan=developer`.
9. Twelve continued requests with the refreshed JWT all return HTTP 200.

Keep this rollout watch visible during the upgrade if desired; no revision or
pod restart should appear:

```bash
oc get pods -n api-monetization-apps --watch
```

### 3. Prove policy and commercial state

```bash
oc get apikey demo-inventory-key -n api-monetization-apps \
  -o jsonpath='{.spec.planTier}{"\n"}'

oc port-forward -n api-monetization-data service/monetization-control 18080:8080
```

Open `http://127.0.0.1:18080` to show the commercial control-plane view. Its API
also exposes the state directly:

```bash
curl --silent http://127.0.0.1:18080/api/subscriptions | jq .
```

### 4. Show observability evidence

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

The Grafana dashboard JSON is managed in the
`api-monetization-grafana-dashboard` ConfigMap. It contains request volume by
plan, customer attribution, latency, and live upgrade counters. Import it into
an existing operator-managed Grafana instance when one is available:

```bash
oc get configmap api-monetization-grafana-dashboard \
  -n api-monetization-observability \
  -o go-template='{{index .data "api-monetization.json"}}'
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

The reset changes both the API-key subscription and the Keycloak machine client
back to Free. Limitador counters are intentionally not deleted; wait for the
one-minute demo window before repeating the burst.
