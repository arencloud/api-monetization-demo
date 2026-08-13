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
    cancel_if_present >/dev/null 2>&1
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
  local method=$1 path=$2 body=${3:-}
  local response_file="$work_dir/portal-response.json"
  local args=(--silent --show-error --output "$response_file" --write-out '%{http_code}'
    --cacert "$work_dir/route-ca.crt"
    --connect-to "$portal_hostname:443:$portal_router:443"
    --header "Authorization: Bearer $developer_token" --request "$method")
  [[ -z $body ]] || args+=(--header 'content-type: application/json' --data "$body")
  local status
  status=$(curl "${args[@]}" "https://$portal_hostname$path")
  if [[ $status -lt 200 || $status -ge 300 ]]; then
    echo "error: $method $path returned HTTP $status: $(cat "$response_file")" >&2
    return 1
  fi
  cat "$response_file"
}

cancel_if_present() {
  local subscription version
  subscription=$(portal_request GET /api/me/subscriptions \
    | jq -c '[.[] | select(.product == "ai-chat")][0] // empty')
  [[ -n $subscription ]] || return 0
  version=$(jq -r '.version' <<<"$subscription")
  portal_request POST /api/me/subscriptions/ai-chat/cancel \
    "$(jq -cn --argjson version "$version" '{version:$version}')" >/dev/null
}

chat_request() {
  local hostname=$1 authorization=$2 label=$3
  local headers="$work_dir/$label.headers" body="$work_dir/$label.json"
  local status
  status=$(curl --silent --show-error --output "$body" --dump-header "$headers" \
    --write-out '%{http_code}' --max-time 180 \
    --cacert "$work_dir/route-ca.crt" \
    --connect-to "$hostname:443:$gateway_router:443" \
    --header "Authorization: $authorization" \
    --header 'content-type: application/json' \
    --data '{"model":"ai-chat","temperature":0,"max_tokens":4,"messages":[{"role":"user","content":"Say OpenShift AI."}]}' \
    "https://$hostname/v1/chat/completions")
  if [[ $status != 200 ]] || ! jq -e '.choices[0].message.content | length > 0' "$body" >/dev/null; then
    echo "error: $label chat request returned HTTP $status: $(cat "$body")" >&2
    return 1
  fi
  local units response_units
  units=$(awk 'BEGIN{IGNORECASE=1} /^x-monetization-billable-units:/ {gsub("\\r", "", $2); print $2}' "$headers" | tail -n1)
  response_units=$(jq -r '.usage.total_tokens // 0' "$body")
  if [[ ! $units =~ ^[1-9][0-9]*$ || $units != "$response_units" ]]; then
    echo "error: $label billed units $units do not match vLLM total tokens $response_units" >&2
    return 1
  fi
  echo "$label returned HTTP 200 and $units billable tokens" >&2
  printf '%s' "$units"
}

echo "preparing a dedicated AI Chat Developer subscription"
cancel_if_present
portal_request POST /api/me/subscriptions \
  '{"product":"ai-chat","plan":"developer"}' >/dev/null

for _ in $(seq 1 60); do
  credential=$(portal_request GET /api/me/credentials/ai-chat/status)
  [[ $(jq -r '.status' <<<"$credential") == ready ]] && break
  sleep 3
done
credential=${credential:-'{}'}
if [[ $(jq -r '.status' <<<"$credential") != ready ]]; then
  echo "error: AI Chat API key did not become ready" >&2
  exit 1
fi
reveal=$(portal_request POST /api/me/credentials/ai-chat/reveal)
api_key=$(jq -r '.apiKey // empty' <<<"$reveal")
[[ -n $api_key ]] || { echo "error: AI Chat API key was not returned" >&2; exit 1; }

api_key_units=$(chat_request "$api_hostname" "APIKEY $api_key" api-key)
jwt_units=$(chat_request "$jwt_hostname" "Bearer $developer_token" jwt)
expected_units=$((api_key_units + jwt_units))

echo "waiting for asynchronous token usage attribution"
recorded_units=0
for _ in $(seq 1 30); do
  usage=$(portal_request GET /api/me/usage)
  recorded_units=$(jq -r '[.[] | select(.product == "ai-chat")][0].requests // 0' <<<"$usage")
  (( recorded_units >= expected_units )) && break
  sleep 2
done
if (( recorded_units < expected_units )); then
  echo "error: portal recorded $recorded_units AI tokens; expected at least $expected_units" >&2
  exit 1
fi

echo "AI Chat monetization passed: API key + JWT, $recorded_units stored token units"
cancel_if_present
