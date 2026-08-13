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

echo "waiting for the CPU model, AI Chat facade, and monetization control plane"
oc wait --for=condition=Ready inferenceservice.serving.kserve.io/ai-chat \
  -n api-monetization-ai --timeout=15m
oc wait --for=condition=Enforced tokenratelimitpolicy.kuadrant.io/ai-chat-api-key-tokens \
  -n api-monetization-apps --timeout=5m
oc wait --for=condition=Enforced tokenratelimitpolicy.kuadrant.io/ai-chat-jwt-tokens \
  -n api-monetization-apps --timeout=5m
oc rollout status deployment/ai-chat-api -n api-monetization-apps --timeout=10m
oc rollout status deployment/monetization-control -n api-monetization-data --timeout=10m

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

limitador_authorized_hits() {
  local policy_namespace=$1
  oc exec -n kuadrant-system deployment/limitador-limitador -c limitador -- \
    curl --silent --show-error --fail http://127.0.0.1:8080/metrics \
    | awk -v metric="authorized_hits{limitador_namespace=\"$policy_namespace\"}" '
        $1 == metric { print int($2); found=1 }
        END { if (!found) print 0 }
      '
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

api_key_hits_before=$(limitador_authorized_hits api-monetization-apps/ai-chat-api-key)
jwt_hits_before=$(limitador_authorized_hits api-monetization-apps/ai-chat-jwt)
api_key_units=$(chat_request "$api_hostname" "APIKEY $api_key" api-key)
jwt_units=$(chat_request "$jwt_hostname" "Bearer $developer_token" jwt)
expected_units=$((api_key_units + jwt_units))

echo "waiting for RHCL to add response tokens to the Limitador counters"
api_key_hits_delta=0
jwt_hits_delta=0
for _ in $(seq 1 30); do
  api_key_hits_after=$(limitador_authorized_hits api-monetization-apps/ai-chat-api-key)
  jwt_hits_after=$(limitador_authorized_hits api-monetization-apps/ai-chat-jwt)
  api_key_hits_delta=$((api_key_hits_after - api_key_hits_before))
  jwt_hits_delta=$((jwt_hits_after - jwt_hits_before))
  if (( api_key_hits_delta >= api_key_units && jwt_hits_delta >= jwt_units )); then
    break
  fi
  sleep 2
done
if (( api_key_hits_delta < api_key_units || jwt_hits_delta < jwt_units )); then
  echo "error: RHCL token counters advanced by API-key=$api_key_hits_delta and JWT=$jwt_hits_delta; expected at least $api_key_units and $jwt_units" >&2
  exit 1
fi
echo "RHCL TokenRateLimitPolicy accounted for API-key=$api_key_hits_delta and JWT=$jwt_hits_delta Limitador hits"

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
