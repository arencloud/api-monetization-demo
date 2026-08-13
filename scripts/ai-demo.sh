#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64 awk; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: $command_name is required" >&2
    exit 1
  }
done

work_dir=$(mktemp -d)
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cleanup_required=false

cleanup() {
  local status=$?
  set +e
  if [[ $cleanup_required == "true" && -n ${developer_token:-} ]] && declare -F cancel_if_present >/dev/null; then
    echo "restoring the reusable AI demo state"
    cancel_if_present >/dev/null 2>&1 || echo "warning: AI demo subscription cleanup is pending; rerun make ai-demo to retry" >&2
  fi
  rm -r -- "$work_dir"
  exit "$status"
}
trap cleanup EXIT

echo "waiting for portable OpenShift Routes"
for route_ref in \
  api-monetization-data/monetization-control \
  api-monetization-gateway/api-monetization \
  api-monetization-gateway/api-monetization-jwt; do
  route_namespace=${route_ref%%/*}
  route_name=${route_ref#*/}
  for _ in $(seq 1 60); do
    oc get "route/$route_name" -n "$route_namespace" >/dev/null 2>&1 && break
    sleep 5
  done
  oc wait "route/$route_name" -n "$route_namespace" \
    --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True \
    --timeout=5m >/dev/null
done

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

for value in "$portal_hostname" "$portal_router" "$api_hostname" "$jwt_hostname" "$gateway_router"; do
  [[ -n $value ]] || { echo "error: one or more required OpenShift Routes are not admitted" >&2; exit 1; }
done

echo "waiting for AI Chat and its Connectivity Link policies"
oc wait --for=condition=Ready inferenceservice.serving.kserve.io/ai-chat \
  -n api-monetization-ai --timeout=15m
oc rollout status deployment/ai-chat-api -n api-monetization-apps --timeout=10m
oc rollout status deployment/monetization-control -n api-monetization-data --timeout=10m
for policy in ai-chat-api-key-tokens ai-chat-jwt-tokens; do
  oc wait --for=condition=Enforced "tokenratelimitpolicy.kuadrant.io/$policy" \
    -n api-monetization-apps --timeout=5m
done
for policy in ai-chat-api-key ai-chat-jwt ai-chat-api-key-preflight ai-chat-jwt-preflight; do
  oc wait --for=condition=Enforced "authpolicy.kuadrant.io/$policy" \
    -n api-monetization-apps --timeout=5m
done

obtain_developer_token() {
  CONTROL_TOKEN_CLIENT_ID=monetization-developer-automation \
    CONTROL_TOKEN_SECRET_NAME=monetization-developer-credentials \
    CONTROL_TOKEN_SECRET_KEY=developer-automation-client-secret \
    "$script_dir/control-token.sh"
}

developer_token=$(obtain_developer_token)

portal_request() {
  local method=$1 path=$2 body=${3:-}
  local response_file="$work_dir/portal-response.json"
  local args=(--silent --show-error --output "$response_file" --write-out '%{http_code}'
    --cacert "$work_dir/route-ca.crt"
    --connect-to "$portal_hostname:443:$portal_router:443"
    --request "$method")
  [[ -z $body ]] || args+=(--header 'content-type: application/json' --data "$body")
  local status attempt
  for attempt in 1 2; do
    status=$(curl "${args[@]}" --header "Authorization: Bearer $developer_token" \
      "https://$portal_hostname$path")
    if [[ $status == 401 && $attempt == 1 ]]; then
      developer_token=$(obtain_developer_token)
      continue
    fi
    if [[ $status -lt 200 || $status -ge 300 ]]; then
      echo "error: $method $path returned HTTP $status: $(cat "$response_file")" >&2
      return 1
    fi
    cat "$response_file"
    return 0
  done
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
  local hostname=$1 authorization=$2 label=$3 payload=$4
  local headers="$work_dir/$label.headers" body="$work_dir/$label.json"
  last_status=$(curl --silent --show-error --output "$body" --dump-header "$headers" \
    --write-out '%{http_code}' --max-time 180 \
    --cacert "$work_dir/route-ca.crt" \
    --connect-to "$hostname:443:$gateway_router:443" \
    --header "Authorization: $authorization" \
    --header "Origin: https://$portal_hostname" \
    --header 'content-type: application/json' \
    --data "$payload" \
    "https://$hostname/v1/chat/completions")
  if ! grep -Eiq '^access-control-allow-origin:[[:space:]]*\*' "$headers"; then
    echo "error: $label response is not accessible to the portable browser playground" >&2
    return 1
  fi
  last_units=0
  if [[ $last_status == 200 ]]; then
    local header_units response_units
    header_units=$(awk 'BEGIN{IGNORECASE=1} /^x-monetization-billable-units:/ {gsub("\\r", "", $2); print $2}' "$headers" | tail -n1)
    response_units=$(jq -r '.usage.total_tokens // 0' "$body")
    if [[ ! $header_units =~ ^[1-9][0-9]*$ || $header_units != "$response_units" ]]; then
      echo "error: $label billing header $header_units does not match response tokens $response_units" >&2
      return 1
    fi
    if ! jq -e '.choices[0].message.content | length > 0' "$body" >/dev/null; then
      echo "error: $label returned no model message: $(cat "$body")" >&2
      return 1
    fi
    last_units=$response_units
  fi
}

verify_preflight() {
  local hostname=$1 label=$2
  local headers="$work_dir/$label-preflight.headers"
  local status
  status=$(curl --silent --show-error --output /dev/null --dump-header "$headers" \
    --write-out '%{http_code}' --max-time 30 \
    --cacert "$work_dir/route-ca.crt" \
    --connect-to "$hostname:443:$gateway_router:443" \
    --request OPTIONS \
    --header "Origin: https://$portal_hostname" \
    --header 'Access-Control-Request-Method: POST' \
    --header 'Access-Control-Request-Headers: authorization,content-type' \
    "https://$hostname/v1/chat/completions")
  if [[ $status != 204 ]] || ! grep -Eiq '^access-control-allow-origin:[[:space:]]*\*' "$headers"; then
    echo "error: $label browser preflight returned HTTP $status without portable CORS headers" >&2
    return 1
  fi
  echo "$label browser preflight allowed (HTTP 204)"
}

exhaust_free_path() {
  local hostname=$1 authorization=$2 label=$3
  chat_request "$hostname" "$authorization" "$label-quota" "$quota_payload"
  if [[ $last_status != 200 || $last_units -lt 1000 ]]; then
    echo "error: $label quota-driving request returned HTTP $last_status and $last_units tokens; expected HTTP 200 and at least 1,000 tokens" >&2
    [[ -f $work_dir/$label-quota.json ]] && cat "$work_dir/$label-quota.json" >&2
    return 1
  fi
  total_accepted_units=$((total_accepted_units + last_units))
  echo "$label consumed $last_units Free-plan tokens"

  local attempt
  for attempt in 1 2 3; do
    chat_request "$hostname" "$authorization" "$label-limited-$attempt" "$short_payload"
    if [[ $last_status == 429 ]]; then
      echo "$label reached the Free token quota (HTTP 429)"
      return 0
    fi
    if [[ $last_status != 200 ]]; then
      echo "error: $label quota check returned unexpected HTTP $last_status" >&2
      cat "$work_dir/$label-limited-$attempt.json" >&2
      return 1
    fi
    total_accepted_units=$((total_accepted_units + last_units))
    sleep 2
  done
  echo "error: $label did not return HTTP 429 after exceeding the Free token quota" >&2
  return 1
}

verify_preflight "$api_hostname" api-key
verify_preflight "$jwt_hostname" jwt

echo "creating a new, counter-isolated Free AI Chat subscription"
cancel_if_present
cleanup_required=true
subscription=$(portal_request POST /api/me/subscriptions '{"product":"ai-chat","plan":"free"}')
subscription_id=$(jq -r '.subscription.id // empty' <<<"$subscription")
[[ -n $subscription_id ]] || { echo "error: AI Chat subscription ID was not returned" >&2; exit 1; }
echo "subscription counter identity: $subscription_id"

credential='{}'
for _ in $(seq 1 60); do
  credential=$(portal_request GET /api/me/credentials/ai-chat/status)
  [[ $(jq -r '.status' <<<"$credential") == ready ]] && break
  sleep 3
done
if [[ $(jq -r '.status' <<<"$credential") != ready ]]; then
  echo "error: AI Chat API key did not become ready" >&2
  exit 1
fi
reveal=$(portal_request POST /api/me/credentials/ai-chat/reveal)
api_key=$(jq -r '.apiKey // empty' <<<"$reveal")
[[ -n $api_key ]] || { echo "error: AI Chat API key was not returned" >&2; exit 1; }

quota_prompt=$(awk 'BEGIN { for (i=0; i<1300; i++) printf "token "; print "Reply with OK." }')
quota_payload=$(jq -cn --arg prompt "$quota_prompt" \
  '{model:"ai-chat",stream:false,temperature:0,max_tokens:4,messages:[{role:"user",content:$prompt}]}')
short_payload='{"model":"ai-chat","stream":false,"temperature":0,"max_tokens":4,"messages":[{"role":"user","content":"Continue after the plan upgrade."}]}'
total_accepted_units=0

echo "proving the Free API-key token quota"
exhaust_free_path "$api_hostname" "APIKEY $api_key" api-key
# Preserve this exact JWT across the policy change. Portal calls can refresh
# developer_token independently if a slow CPU inference outlives its five-minute
# access-token lifetime.
gateway_token=$(obtain_developer_token)
echo "proving the Free JWT token quota with the JWT issued before upgrade"
exhaust_free_path "$jwt_hostname" "Bearer $gateway_token" jwt

echo "upgrading the same subscription from Free to Developer"
upgrade=$(portal_request POST /api/me/subscriptions/ai-chat/plan '{"plan":"developer"}')
if [[ $(jq -r '.plan' <<<"$upgrade") != developer || $(jq -r '.id' <<<"$upgrade") != "$subscription_id" ]]; then
  echo "error: live AI plan upgrade did not preserve the subscription identity" >&2
  exit 1
fi

for credential_mode in api-key jwt; do
  if [[ $credential_mode == api-key ]]; then
    hostname=$api_hostname
    authorization="APIKEY $api_key"
  else
    hostname=$jwt_hostname
    authorization="Bearer $gateway_token"
  fi
  chat_request "$hostname" "$authorization" "$credential_mode-developer" "$short_payload"
  if [[ $last_status != 200 ]]; then
    echo "error: $credential_mode did not continue after Developer upgrade (HTTP $last_status)" >&2
    cat "$work_dir/$credential_mode-developer.json" >&2
    exit 1
  fi
  total_accepted_units=$((total_accepted_units + last_units))
  echo "$credential_mode continued immediately under Developer with $last_units billable tokens"
done

echo "waiting for PostgreSQL token attribution"
recorded_units=0
for _ in $(seq 1 30); do
  usage=$(portal_request GET /api/me/usage)
  ai_usage=$(jq -c '[.[] | select(.product == "ai-chat")][0] // {}' <<<"$usage")
  recorded_units=$(jq -r '.requests // 0' <<<"$ai_usage")
  (( recorded_units >= total_accepted_units )) && break
  sleep 2
done
if (( recorded_units < total_accepted_units )); then
  echo "error: portal recorded $recorded_units AI tokens; expected at least $total_accepted_units" >&2
  exit 1
fi
remaining=$(jq -r '(.monthlyQuotaRequests // 0) - (.requests // 0) | if . < 0 then 0 else . end' <<<"$ai_usage")
revenue=$(jq -r '.projectedRevenueEuro // 0' <<<"$ai_usage")
if [[ $(jq -r '.plan' <<<"$ai_usage") != developer || $remaining -le 0 ]]; then
  echo "error: Developer usage summary does not show a positive remaining token quota" >&2
  jq . <<<"$ai_usage" >&2
  exit 1
fi

echo "AI DEMO RESULT: PASS"
echo "  stored billable tokens: $recorded_units"
echo "  Developer tokens remaining: $remaining"
echo "  projected AI revenue: €$revenue"
echo "  API key and the already-issued JWT both continued after the live upgrade"

cancel_if_present
cleanup_required=false
echo "reusable state restored: the automation AI subscription is cancelled and credential cleanup was requested"
