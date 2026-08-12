#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64 sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

application_namespace=api-monetization-apps
data_namespace=api-monetization-data
gateway_namespace=api-monetization-gateway
control_port=${LIFECYCLE_CONTROL_LOCAL_PORT:-18090}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d)
port_forward_pid=""
route_ca_file="$work_dir/route-ca.crt"
response_file="$work_dir/response.json"
api_status=""
cleanup_subscription=false

cleanup() {
  if [[ $cleanup_subscription == "true" && -n ${developer_token:-} && \
    -n $port_forward_pid ]] && kill -0 "$port_forward_pid" 2>/dev/null; then
    curl --silent --output "$response_file" \
      --header "Authorization: Bearer $developer_token" \
      "http://127.0.0.1:$control_port/api/me/subscriptions" 2>/dev/null || true
    cleanup_version=$(jq -r '[.[] | select(.product == "inventory")][0].version // empty' \
      "$response_file" 2>/dev/null || true)
    if [[ -n $cleanup_version ]]; then
      curl --silent --output /dev/null --request POST \
        --header "Authorization: Bearer $developer_token" \
        --header 'Content-Type: application/json' \
        --data "$(jq -cn --argjson version "$cleanup_version" '{version:$version}')" \
        "http://127.0.0.1:$control_port/api/me/subscriptions/inventory/cancel" \
        2>/dev/null || true
    fi
  fi
  if [[ -n $port_forward_pid ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

wait_for_application() {
  local name=$1
  local state=""
  for _ in $(seq 1 120); do
    state=$(oc get application.argoproj.io "$name" -n openshift-gitops \
      -o jsonpath='{.status.sync.status}{"|"}{.status.health.status}' \
      2>/dev/null || true)
    if [[ $state == "Synced|Healthy" ]]; then
      return 0
    fi
    sleep 5
  done
  fail "$name did not become Synced and Healthy (last state: ${state:-not found})"
}

control_request() {
  local token=$1
  local method=$2
  local path=$3
  local body=${4:-}
  local -a arguments=(
    --silent --show-error --output "$response_file" --write-out '%{http_code}'
    --request "$method"
    --header "Authorization: Bearer $token"
  )
  if [[ -n $body ]]; then
    arguments+=(--header 'Content-Type: application/json' --data "$body")
  fi
  api_status=$(curl "${arguments[@]}" "http://127.0.0.1:$control_port$path")
}

expect_api_status() {
  local expected=$1
  local operation=$2
  if [[ $api_status != "$expected" ]]; then
    local message
    message=$(jq -r '.error // empty' "$response_file" 2>/dev/null || true)
    fail "$operation returned HTTP $api_status instead of $expected${message:+: $message}"
  fi
}

wait_for_credential_absence() {
  local api_key_name=$1
  local secret_name="${api_key_name}-key"
  local generator_name="${api_key_name}-generator"
  for _ in $(seq 1 60); do
    if ! oc get apikey.devportal.kuadrant.io "$api_key_name" \
        -n "$application_namespace" >/dev/null 2>&1 && \
      ! oc get externalsecret.external-secrets.io "$secret_name" \
        -n "$application_namespace" >/dev/null 2>&1 && \
      ! oc get secret "$secret_name" -n "$application_namespace" >/dev/null 2>&1 && \
      ! oc get password.generators.external-secrets.io "$generator_name" \
        -n "$application_namespace" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  fail "operator-managed credential resources for $api_key_name were not removed"
}

wait_for_credential() {
  local api_key_name=$1
  local secret_name="${api_key_name}-key"
  for _ in $(seq 1 120); do
    if oc get secret "$secret_name" -n "$application_namespace" >/dev/null 2>&1 && \
      [[ $(oc get apikey.devportal.kuadrant.io "$api_key_name" \
        -n "$application_namespace" \
        -o jsonpath='{range .status.conditions[?(@.type=="Approved")]}{.status}{end}' \
        2>/dev/null || true) == "True" ]]; then
      return 0
    fi
    sleep 2
  done
  fail "operator-managed credential $api_key_name was not approved"
}

request_api_key() {
  local api_key=$1
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert "$route_ca_file" \
    --connect-to "$api_hostname:443:$router_hostname:443" \
    --header "Host: $api_hostname" \
    --header "Authorization: APIKEY $api_key" \
    "https://$api_hostname/inventory"
}

request_jwt() {
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert "$route_ca_file" \
    --connect-to "$jwt_hostname:443:$router_hostname:443" \
    --header "Host: $jwt_hostname" \
    --header "Authorization: Bearer $developer_token" \
    "https://$jwt_hostname/inventory"
}

expect_allowed() {
  local credential=$1
  local status=$2
  [[ $status == "200" ]] || fail "$credential request returned HTTP $status instead of 200"
  echo "$credential request allowed (HTTP 200)"
}

expect_blocked() {
  local credential=$1
  local status=$2
  local expected=$3
  [[ $status == "$expected" ]] || \
    fail "$credential request returned HTTP $status instead of the expected denial HTTP $expected"
  echo "$credential request blocked (HTTP $status)"
}

cancel_current_subscription() {
  control_request "$developer_token" GET /api/me/subscriptions
  expect_api_status 200 "load developer subscriptions"
  local current
  current=$(jq -c '[.[] | select(.product == "inventory")][0] // empty' "$response_file")
  if [[ -z $current ]]; then
    return 0
  fi
  local version
  version=$(jq -er '.version' <<<"$current")
  control_request "$developer_token" POST /api/me/subscriptions/inventory/cancel \
    "$(jq -cn --argjson version "$version" '{version:$version}')"
  if [[ $api_status != "200" && $api_status != "202" ]]; then
    expect_api_status 200 "cancel existing automation subscription"
  fi
  wait_for_credential_absence "$api_key_name"
}

for application in api-monetization-identity api-monetization-control api-monetization-gateway; do
  wait_for_application "$application"
done

echo "obtaining dedicated lifecycle-test identities"
admin_token=$("$script_dir/control-token.sh")
developer_token=$(CONTROL_TOKEN_CLIENT_ID=monetization-developer-automation \
  CONTROL_TOKEN_SECRET_NAME=monetization-developer-credentials \
  CONTROL_TOKEN_SECRET_KEY=developer-automation-client-secret \
  "$script_dir/control-token.sh")

developer_payload=${developer_token#*.}
developer_payload=${developer_payload%%.*}
case $((${#developer_payload} % 4)) in
  0) ;;
  2) developer_payload+="==" ;;
  3) developer_payload+="=" ;;
  *) fail "developer automation token has an invalid JWT payload" ;;
esac
developer_claims=$(printf '%s' "$developer_payload" | tr '_-' '/+' | base64 -d 2>/dev/null) || \
  fail "developer automation token payload could not be decoded"
if ! jq -e '.aud | if type == "array" then index("api-monetization") != null else . == "api-monetization" end' \
  <<<"$developer_claims" >/dev/null; then
  fail "developer automation token lacks the api-monetization audience; wait for the identity GitOps application"
fi
developer_subject=$(jq -er '.sub' <<<"$developer_claims")
customer_hash=$(printf 'api-monetization:%s' "$developer_subject" | sha256sum)
customer_id="dev-${customer_hash:0:24}"
api_key_name="${customer_id}-inventory"

echo "starting the monetization control-plane tunnel"
oc port-forward -n "$data_namespace" service/monetization-control \
  "$control_port:8080" >"$work_dir/control-port-forward.log" 2>&1 &
port_forward_pid=$!
for _ in $(seq 1 30); do
  if curl --silent --fail "http://127.0.0.1:$control_port/readyz" >/dev/null 2>&1; then
    break
  fi
  kill -0 "$port_forward_pid" 2>/dev/null || \
    fail "control-plane port-forward stopped; local port $control_port may be in use"
  sleep 1
done
curl --silent --fail "http://127.0.0.1:$control_port/readyz" >/dev/null || \
  fail "monetization control plane did not become ready"

api_hostname=$(oc get route api-monetization -n "$gateway_namespace" \
  -o jsonpath='{.status.ingress[0].host}')
jwt_hostname=$(oc get route api-monetization-jwt -n "$gateway_namespace" \
  -o jsonpath='{.status.ingress[0].host}')
router_hostname=$(oc get route api-monetization -n "$gateway_namespace" \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
[[ -n $api_hostname && -n $jwt_hostname && -n $router_hostname ]] || \
  fail "OpenShift Routes are not admitted"
ingress_certificate=$(oc get ingresscontroller.operator.openshift.io default \
  -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
if [[ -z $ingress_certificate ]]; then
  ingress_certificate=router-certs-default
fi
oc get secret "$ingress_certificate" -n openshift-ingress \
  -o go-template='{{index .data "tls.crt"}}' | base64 -d >"$route_ca_file"

echo "resetting only the dedicated automation subscription"
cancel_current_subscription

echo "creating a Developer-plan subscription and operator-managed API key"
control_request "$developer_token" POST /api/me/subscriptions \
  '{"product":"inventory","plan":"developer"}'
expect_api_status 201 "create developer automation subscription"
cleanup_subscription=true
created_customer=$(jq -er '.subscription.customerId' "$response_file")
[[ $created_customer == "$customer_id" ]] || \
  fail "created customer $created_customer does not match expected automation customer $customer_id"
wait_for_credential "$api_key_name"
control_request "$developer_token" POST /api/me/credentials/inventory/reveal
expect_api_status 200 "reveal lifecycle-test API key"
first_api_key=$(jq -er '.apiKey' "$response_file")

echo "proving active API-key and already-issued JWT access"
expect_allowed "API key" "$(request_api_key "$first_api_key")"
expect_allowed "JWT" "$(request_jwt)"

control_request "$admin_token" GET /api/subscriptions
expect_api_status 200 "load administrator subscriptions"
version=$(jq -er --arg customer "$customer_id" \
  '.[] | select(.customerId == $customer and .product == "inventory") | .version' \
  "$response_file")

echo "suspending access as an administrator"
control_request "$admin_token" POST "/api/subscriptions/$customer_id/status" \
  "$(jq -cn --argjson version "$version" '{status:"suspended",version:$version}')"
expect_api_status 200 "suspend automation subscription"
suspended_version=$(jq -er '.version' "$response_file")
expect_blocked "API key" "$(request_api_key "$first_api_key")" 403
expect_blocked "JWT" "$(request_jwt)" 403

echo "resuming access without regenerating either credential"
control_request "$admin_token" POST "/api/subscriptions/$customer_id/status" \
  "$(jq -cn --argjson version "$suspended_version" '{status:"active",version:$version}')"
expect_api_status 200 "resume automation subscription"
resumed_version=$(jq -er '.version' "$response_file")
expect_allowed "original API key" "$(request_api_key "$first_api_key")"
expect_allowed "already-issued JWT" "$(request_jwt)"

echo "cancelling as the developer and verifying immediate denial and cleanup"
control_request "$developer_token" POST /api/me/subscriptions/inventory/cancel \
  "$(jq -cn --argjson version "$resumed_version" '{version:$version}')"
if [[ $api_status != "200" && $api_status != "202" ]]; then
  expect_api_status 200 "cancel automation subscription"
fi
cleanup_subscription=false
expect_blocked "cancelled API key" "$(request_api_key "$first_api_key")" 401
expect_blocked "cancelled JWT" "$(request_jwt)" 403
wait_for_credential_absence "$api_key_name"

echo "resubscribing and proving a new API key plus the same JWT identity"
control_request "$developer_token" POST /api/me/subscriptions \
  '{"product":"inventory","plan":"developer"}'
expect_api_status 201 "resubscribe developer automation identity"
cleanup_subscription=true
wait_for_credential "$api_key_name"
control_request "$developer_token" POST /api/me/credentials/inventory/reveal
expect_api_status 200 "reveal replacement API key"
replacement_api_key=$(jq -er '.apiKey' "$response_file")
[[ $replacement_api_key != "$first_api_key" ]] || \
  fail "resubscription reused the revoked API key"
control_request "$developer_token" GET /api/me/subscriptions
expect_api_status 200 "load replacement subscription"
replacement_version=$(jq -er \
  '[.[] | select(.product == "inventory" and .status == "active")][0].version' \
  "$response_file")
expect_allowed "replacement API key" "$(request_api_key "$replacement_api_key")"
expect_allowed "existing JWT identity" "$(request_jwt)"

echo "verifying lifecycle audit records"
control_request "$developer_token" GET /api/me/audit
expect_api_status 200 "load lifecycle audit"
for event_type in subscription-suspended subscription-active subscription-cancelled; do
  jq -e --arg type "$event_type" 'any(.[]; .type == $type)' "$response_file" >/dev/null || \
    fail "lifecycle audit is missing $event_type"
done

echo "returning the automation identity to a clean cancelled state"
control_request "$developer_token" POST /api/me/subscriptions/inventory/cancel \
  "$(jq -cn --argjson version "$replacement_version" '{version:$version}')"
if [[ $api_status != "200" && $api_status != "202" ]]; then
  expect_api_status 200 "final automation subscription cleanup"
fi
cleanup_subscription=false
wait_for_credential_absence "$api_key_name"
expect_blocked "final API key" "$(request_api_key "$replacement_api_key")" 401
expect_blocked "final JWT" "$(request_jwt)" 403

echo "lifecycle test passed: active, suspend, resume, cancel, cleanup, and resubscribe are enforced"
