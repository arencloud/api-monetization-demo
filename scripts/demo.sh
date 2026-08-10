#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

gateway_namespace=api-monetization-gateway
gateway_name=api-monetization
application_namespace=api-monetization-apps
data_namespace=api-monetization-data
api_hostname=api-monetization.demo
jwt_hostname=jwt.api-monetization.demo
control_port=${CONTROL_LOCAL_PORT:-18080}
keycloak_port=${KEYCLOAK_LOCAL_PORT:-18081}
port_forward_pids=()

cleanup() {
  for pid in "${port_forward_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

echo "waiting for gateway and generated demo API key"
oc wait --for=condition=Programmed "gateway.gateway.networking.k8s.io/$gateway_name" \
  -n "$gateway_namespace" --timeout=10m
oc wait --for=condition=Ready apikey.devportal.kuadrant.io/demo-inventory-key \
  -n "$application_namespace" --timeout=5m

gateway_address=$(oc get gateway "$gateway_name" -n "$gateway_namespace" \
  -o jsonpath='{.status.addresses[0].value}')
secret_name=$(oc get apikey.devportal.kuadrant.io/demo-inventory-key \
  -n "$application_namespace" -o jsonpath='{.status.secretRef.name}')
api_key=$(oc get secret "$secret_name" -n "$application_namespace" \
  -o go-template='{{index .data "api_key"}}' | base64 -d)

request_api_key() {
  curl --silent --output /dev/null --write-out '%{http_code}' \
    --header "Host: $api_hostname" \
    --header "Authorization: APIKEY $api_key" \
    "http://$gateway_address/inventory"
}

echo "baseline: unauthenticated request"
unauthenticated=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header "Host: $api_hostname" "http://$gateway_address/inventory")
echo "HTTP $unauthenticated (expected 401)"

echo "free plan burst: 12 requests against the 10/minute limit"
for request_number in $(seq 1 12); do
  echo "request $request_number -> HTTP $(request_api_key)"
done

echo "starting the monetization control plane tunnel"
oc port-forward -n "$data_namespace" service/monetization-control \
  "$control_port:8080" >/tmp/api-monetization-control-port-forward.log 2>&1 &
port_forward_pids+=("$!")
for _ in $(seq 1 30); do
  curl --silent --fail "http://127.0.0.1:$control_port/readyz" >/dev/null && break
  sleep 1
done

echo "upgrading demo-company from Free to Developer"
curl --silent --fail-with-body \
  --header 'content-type: application/json' \
  --data '{"plan":"developer"}' \
  "http://127.0.0.1:$control_port/api/subscriptions/demo-company/plan" | jq .

echo "request after live upgrade -> HTTP $(request_api_key) (expected 200)"

echo "validating the Keycloak JWT path"
keycloak_host=api-monetization-service.api-monetization-identity.svc.cluster.local
oc port-forward -n api-monetization-identity service/api-monetization-service \
  "$keycloak_port:8080" >/tmp/api-monetization-keycloak-port-forward.log 2>&1 &
port_forward_pids+=("$!")
client_secret=$(oc get secret keycloak-demo-clients -n api-monetization-identity \
  -o go-template='{{index .data "free-client-secret"}}' | base64 -d)
for _ in $(seq 1 30); do
  if token_response=$(curl --silent --fail \
    --connect-to "$keycloak_host:8080:127.0.0.1:$keycloak_port" \
    --user "demo-free-client:$client_secret" \
    --data 'grant_type=client_credentials' \
    "http://$keycloak_host:8080/realms/api-monetization/protocol/openid-connect/token"); then
    break
  fi
  sleep 1
done
jwt=$(jq -er '.access_token' <<<"$token_response")
jwt_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header "Host: $jwt_hostname" \
  --header "Authorization: Bearer $jwt" \
  "http://$gateway_address/inventory")
echo "JWT request -> HTTP $jwt_status (expected 200)"

echo "demo complete: authentication, Free-tier 429, live upgrade, and JWT validation were exercised"
