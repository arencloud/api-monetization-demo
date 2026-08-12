#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: $command_name is required" >&2
    exit 1
  }
done

request_count=${METERED_DEMO_REQUESTS:-5}
[[ $request_count =~ ^[1-9][0-9]*$ && $request_count -le 100 ]] || {
  echo "error: METERED_DEMO_REQUESTS must be between 1 and 100" >&2
  exit 1
}

application_namespace=api-monetization-apps
data_namespace=api-monetization-data
gateway_namespace=api-monetization-gateway
control_port=${METERED_CONTROL_LOCAL_PORT:-18097}
token_port=${METERED_TOKEN_LOCAL_PORT:-18098}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d)
port_forward_pid=""

cleanup() {
  if [[ -n $port_forward_pid ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi
  rm -r -- "$work_dir"
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

for application in api-monetization-control api-monetization-gateway; do
  state=$(oc get application.argoproj.io "$application" -n openshift-gitops \
    -o jsonpath='{.status.sync.status}{"|"}{.status.health.status}' 2>/dev/null || true)
  [[ $state == "Synced|Healthy" ]] || fail "$application is ${state:-not ready}; wait for GitOps"
done

oc wait --for=condition=Approved apikey.devportal.kuadrant.io/demo-inventory-key \
  -n "$application_namespace" --timeout=5m >/dev/null

echo "starting the monetization control-plane tunnel"
oc port-forward -n "$data_namespace" service/monetization-control \
  "$control_port:8080" >"$work_dir/control-port-forward.log" 2>&1 &
port_forward_pid=$!
for _ in $(seq 1 30); do
  curl --silent --fail "http://127.0.0.1:$control_port/readyz" >/dev/null 2>&1 && break
  kill -0 "$port_forward_pid" 2>/dev/null || fail "control-plane tunnel stopped; local port $control_port may be in use"
  sleep 1
done
curl --silent --fail "http://127.0.0.1:$control_port/readyz" >/dev/null || \
  fail "monetization control plane did not become ready"

control_token=$(CONTROL_TOKEN_LOCAL_PORT="$token_port" "$script_dir/control-token.sh")
auth_header="Authorization: Bearer $control_token"

plans=$(curl --silent --show-error --fail --header "$auth_header" \
  "http://127.0.0.1:$control_port/api/plans")
jq -e 'any(.[]; .id == "payg" and .includedRequests == 0 and .monthlyQuotaRequests == 10000)' \
  <<<"$plans" >/dev/null || fail "Pay as you go plan is not deployed yet"

echo "changing Demo Company to Pay as you go"
curl --silent --show-error --fail-with-body \
  --header "$auth_header" --header 'Content-Type: application/json' \
  --data '{"plan":"payg"}' \
  "http://127.0.0.1:$control_port/api/subscriptions/demo-company/plan" \
  >"$work_dir/subscription.json"
jq -e '.plan == "payg"' "$work_dir/subscription.json" >/dev/null || \
  fail "control plane did not apply the Pay as you go plan"

for _ in $(seq 1 60); do
  plan_tier=$(oc get apikey.devportal.kuadrant.io demo-inventory-key \
    -n "$application_namespace" -o jsonpath='{.spec.planTier}' 2>/dev/null || true)
  [[ $plan_tier == payg ]] && break
  sleep 1
done
[[ ${plan_tier:-} == payg ]] || fail "RHCL API key did not reconcile to Pay as you go"

usage=$(curl --silent --show-error --fail --header "$auth_header" \
  "http://127.0.0.1:$control_port/api/usage")
baseline=$(jq -r '[.[] | select(.customer == "demo-company" and .product == "inventory")][0].requests // 0' \
  <<<"$usage")
target=$((baseline + request_count))

secret_name=$(oc get apikey.devportal.kuadrant.io demo-inventory-key \
  -n "$application_namespace" -o jsonpath='{.spec.secretRef.name}')
api_key=$(oc get secret "$secret_name" -n "$application_namespace" \
  -o go-template='{{index .data "api_key"}}' | base64 -d)
api_hostname=$(oc get route api-monetization -n "$gateway_namespace" \
  -o jsonpath='{.status.ingress[0].host}')
router_hostname=$(oc get route api-monetization -n "$gateway_namespace" \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
ingress_certificate=$(oc get ingresscontroller.operator.openshift.io default \
  -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
[[ -n $ingress_certificate ]] || ingress_certificate=router-certs-default
oc get secret "$ingress_certificate" -n openshift-ingress \
  -o go-template='{{index .data "tls.crt"}}' | base64 -d >"$work_dir/route-ca.crt"

echo "sending $request_count real accepted requests through OpenShift Route, Gateway API, and Connectivity Link"
for request_number in $(seq 1 "$request_count"); do
  status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert "$work_dir/route-ca.crt" \
    --connect-to "$api_hostname:443:$router_hostname:443" \
    --header "Host: $api_hostname" \
    --header "Authorization: APIKEY $api_key" \
    "https://$api_hostname/inventory")
  [[ $status == 200 ]] || fail "metered request $request_number returned HTTP $status instead of 200"
  echo "metered request $request_number -> HTTP 200"
done

echo "waiting for asynchronous usage attribution"
current=$baseline
for _ in $(seq 1 30); do
  usage=$(curl --silent --show-error --fail --header "$auth_header" \
    "http://127.0.0.1:$control_port/api/usage")
  current=$(jq -r '[.[] | select(.customer == "demo-company" and .product == "inventory")][0].requests // 0' \
    <<<"$usage")
  [[ $current -ge $target ]] && break
  sleep 1
done
[[ $current -ge $target ]] || fail "only $current requests were stored; expected at least $target"

curl --silent --show-error --fail-with-body --request POST \
  --header "$auth_header" \
  "http://127.0.0.1:$control_port/api/subscriptions/demo-company/invoices/draft" \
  >"$work_dir/invoice.json"
overage_units=$(jq -r '[.items[] | select(.product == "inventory" and .plan == "payg")][0].overageUnits // -1' \
  "$work_dir/invoice.json")
overage_cents=$(jq -r '.overageCents' "$work_dir/invoice.json")
[[ $overage_units -ge $target ]] || fail "invoice contains $overage_units metered units; expected at least $target"

echo
echo "real metered billing result"
jq '{customerId,periodStart,periodEnd,currency,overageCents,totalCents,items:[.items[] | select(.plan == "payg") | {product,plan,billableUnits,includedUnits,overageUnits,overageCents,totalCents}]}' \
  "$work_dir/invoice.json"
echo "$request_count new accepted requests increased stored usage from $baseline to $current"
echo "All $overage_units accepted Pay-as-you-go requests are billable overage (€$(printf '%d.%02d' $((overage_cents / 100)) $((overage_cents % 100))))"
echo "HTTP 429 requests are rejected before the API and are never added to this invoice"
echo "Run 'make reset-demo' when finished to return Demo Company to Free"
