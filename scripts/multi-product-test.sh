#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: $command_name is required" >&2
    exit 1
  }
done

work_dir=$(mktemp -d)

cleanup() {
  local status=$?
  set +e
  if [[ -n ${developer_token:-} ]] && declare -F cancel_if_present >/dev/null; then
    for product in inventory payments; do
      cancel_if_present "$product" >/dev/null 2>&1
    done
  fi
  rm -r -- "$work_dir"
  exit "$status"
}
trap cleanup EXIT

ingress_certificate=$(oc get ingresscontroller.operator.openshift.io default \
  -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
[[ -n $ingress_certificate ]] || ingress_certificate=router-certs-default
oc get secret "$ingress_certificate" -n openshift-ingress \
  -o go-template='{{index .data "tls.crt"}}' | base64 -d >"$work_dir/route-ca.crt"

portal_hostname=$(oc get route monetization-control -n api-monetization-data \
  -o jsonpath='{.status.ingress[0].host}')
portal_router=$(oc get route monetization-control -n api-monetization-data \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
api_hostname=$(oc get route api-monetization -n api-monetization-gateway \
  -o jsonpath='{.status.ingress[0].host}')
jwt_hostname=$(oc get route api-monetization-jwt -n api-monetization-gateway \
  -o jsonpath='{.status.ingress[0].host}')
gateway_router=$(oc get route api-monetization -n api-monetization-gateway \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')

developer_token=$(CONTROL_TOKEN_CLIENT_ID=monetization-developer-automation \
  CONTROL_TOKEN_SECRET_NAME=monetization-developer-credentials \
  CONTROL_TOKEN_SECRET_KEY=developer-automation-client-secret \
  "$(dirname "${BASH_SOURCE[0]}")/control-token.sh")

portal_request() {
  local method=$1
  local path=$2
  local body=${3:-}
  local response_file="$work_dir/response.json"
  local args=(
    --silent --show-error --output "$response_file" --write-out '%{http_code}'
    --cacert "$work_dir/route-ca.crt"
    --connect-to "$portal_hostname:443:$portal_router:443"
    --header "Authorization: Bearer $developer_token"
    --request "$method"
  )
  if [[ -n $body ]]; then
    args+=(--header 'content-type: application/json' --data "$body")
  fi
  local status
  status=$(curl "${args[@]}" "https://$portal_hostname$path")
  if [[ $status -lt 200 || $status -ge 300 ]]; then
    echo "error: $method $path returned HTTP $status: $(cat "$response_file")" >&2
    return 1
  fi
  cat "$response_file"
}

cancel_if_present() {
  local product=$1
  local subscription
  subscription=$(portal_request GET /api/me/subscriptions \
    | jq -c --arg product "$product" '[.[] | select(.product == $product)][0] // empty')
  [[ -n $subscription ]] || return 0
  local version
  version=$(jq -r '.version' <<<"$subscription")
  echo "removing previous $product test subscription"
  portal_request POST "/api/me/subscriptions/$product/cancel" \
    "$(jq -cn --argjson version "$version" '{version:$version}')" >/dev/null
}

subscribe_product() {
  local product=$1
  local plan=$2
  echo "subscribing to $product on the $plan plan"
  portal_request POST /api/me/subscriptions \
    "$(jq -cn --arg product "$product" --arg plan "$plan" '{product:$product,plan:$plan}')" >/dev/null
}

wait_for_credential() {
  local product=$1
  local credential=""
  for _ in $(seq 1 60); do
    credential=$(portal_request GET "/api/me/credentials/$product/status")
    if [[ $(jq -r '.status' <<<"$credential") == ready ]]; then
      printf '%s' "$credential"
      return 0
    fi
    sleep 3
  done
  echo "error: $product API key did not become ready" >&2
  return 1
}

gateway_status() {
  local hostname=$1
  local path=$2
  local authorization=$3
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert "$work_dir/route-ca.crt" \
    --connect-to "$hostname:443:$gateway_router:443" \
    --header "Authorization: $authorization" \
    "https://$hostname$path"
}

for product in inventory payments; do
  cancel_if_present "$product"
done

subscribe_product inventory free
subscribe_product payments developer

for product in inventory payments; do
  wait_for_credential "$product" >/dev/null
done

subscriptions=$(portal_request GET /api/me/subscriptions)
if ! jq -e '
  any(.[]; .product == "inventory" and .plan == "free") and
  any(.[]; .product == "payments" and .plan == "developer")
' <<<"$subscriptions" >/dev/null; then
  echo "error: independent Inventory Free and Payment Developer subscriptions were not created" >&2
  exit 1
fi
echo "independent plans confirmed: Inventory=Free, Payment=Developer"

for product in inventory payments; do
  reveal=$(portal_request POST "/api/me/credentials/$product/reveal")
  api_key=$(jq -r '.apiKey // empty' <<<"$reveal")
  [[ -n $api_key ]] || {
    echo "error: $product API key was not returned" >&2
    exit 1
  }
  path="/$product"
  [[ $product == inventory ]] && path=/inventory
  status=$(gateway_status "$api_hostname" "$path" "APIKEY $api_key")
  [[ $status == 200 ]] || {
    echo "error: $product API-key request returned HTTP $status" >&2
    exit 1
  }
  status=$(gateway_status "$jwt_hostname" "$path" "Bearer $developer_token")
  [[ $status == 200 ]] || {
    echo "error: $product JWT request returned HTTP $status" >&2
    exit 1
  }
  echo "$product API key and the shared Keycloak identity both returned HTTP 200"
done

usage=$(portal_request GET /api/me/usage)
if ! jq -e '
  any(.[]; .product == "inventory" and .unitName == "request" and (.billableUnits | type) == "number") and
  any(.[]; .product == "payments" and .unitName == "request" and (.billableUnits | type) == "number")
' <<<"$usage" >/dev/null; then
  echo "error: commercial usage does not expose both request-based product subscriptions with native units" >&2
  exit 1
fi
echo "commercial usage is attributed independently to both products"

for product in inventory payments; do
  cancel_if_present "$product"
done
echo "multi-product test passed and its subscriptions were cancelled"
