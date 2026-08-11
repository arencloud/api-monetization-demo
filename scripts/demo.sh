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
control_port=${CONTROL_LOCAL_PORT:-18080}
keycloak_port=${KEYCLOAK_LOCAL_PORT:-18081}
port_forward_pids=()
route_ca_file=""

cleanup() {
  for pid in "${port_forward_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  if [[ -n $route_ca_file ]]; then
    rm -f "$route_ca_file"
  fi
}
trap cleanup EXIT

echo "waiting for gateway and generated demo API key"
oc wait --for=condition=Programmed "gateway.gateway.networking.k8s.io/$gateway_name" \
  -n "$gateway_namespace" --timeout=10m
oc wait route/api-monetization -n "$gateway_namespace" \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m
oc wait route/api-monetization-jwt -n "$gateway_namespace" \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m
oc wait --for=condition=Approved apikey.devportal.kuadrant.io/demo-inventory-key \
  -n "$application_namespace" --timeout=5m

api_hostname=$(oc get route api-monetization -n "$gateway_namespace" \
  -o jsonpath='{.status.ingress[0].host}')
jwt_hostname=$(oc get route api-monetization-jwt -n "$gateway_namespace" \
  -o jsonpath='{.status.ingress[0].host}')
router_hostname=$(oc get route api-monetization -n "$gateway_namespace" \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
if [[ -z $router_hostname ]]; then
  echo "error: the OpenShift router did not publish a canonical hostname" >&2
  exit 1
fi
ingress_certificate=$(oc get ingresscontroller.operator.openshift.io default \
  -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
if [[ -z $ingress_certificate ]]; then
  ingress_certificate=router-certs-default
fi
route_ca_file=$(mktemp)
oc get secret "$ingress_certificate" -n openshift-ingress \
  -o go-template='{{index .data "tls.crt"}}' | base64 -d >"$route_ca_file"
echo "API-key endpoint: https://$api_hostname/inventory"
echo "JWT endpoint: https://$jwt_hostname/inventory"
secret_name=$(oc get apikey.devportal.kuadrant.io/demo-inventory-key \
  -n "$application_namespace" -o jsonpath='{.spec.secretRef.name}')
api_key=$(oc get secret "$secret_name" -n "$application_namespace" \
  -o go-template='{{index .data "api_key"}}' | base64 -d)
plan_tier=$(oc get apikey.devportal.kuadrant.io/demo-inventory-key \
  -n "$application_namespace" -o jsonpath='{.spec.planTier}')
if [[ $plan_tier != "free" ]]; then
  echo "error: demo-inventory-key is on the $plan_tier plan; run 'make reset-demo', wait 60 seconds for rate-limit counters to expire, and retry" >&2
  exit 1
fi

request_api_key() {
  curl --silent --output /dev/null --write-out '%{http_code}' \
    --cacert "$route_ca_file" \
    --connect-to "$api_hostname:443:$router_hostname:443" \
    --header "Host: $api_hostname" \
    --header "Authorization: APIKEY $api_key" \
    "https://$api_hostname/inventory"
}

echo "baseline: unauthenticated request"
unauthenticated=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --cacert "$route_ca_file" \
  --connect-to "$api_hostname:443:$router_hostname:443" \
  --header "Host: $api_hostname" "https://$api_hostname/inventory")
echo "HTTP $unauthenticated (expected 401)"
if [[ $unauthenticated != "401" ]]; then
  echo "error: unauthenticated request did not return HTTP 401" >&2
  exit 1
fi

echo "free plan burst: 12 requests against the 10/minute limit"
successful_requests=0
limited_requests=0
for request_number in $(seq 1 12); do
  request_status=$(request_api_key)
  echo "request $request_number -> HTTP $request_status"
  case "$request_status" in
    200)
      successful_requests=$((successful_requests + 1))
      ;;
    429)
      limited_requests=$((limited_requests + 1))
      ;;
    *)
      echo "error: Free-plan request returned unexpected HTTP $request_status" >&2
      exit 1
      ;;
  esac
done
if ((successful_requests == 0 || limited_requests == 0)); then
  echo "error: Free-plan burst did not demonstrate both accepted and rate-limited requests; run 'make reset-demo', wait 60 seconds, and retry" >&2
  exit 1
fi

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

upgraded_status=$(request_api_key)
echo "request after live upgrade -> HTTP $upgraded_status (expected 200)"
if [[ $upgraded_status != "200" ]]; then
  echo "error: request after the Developer-plan upgrade did not return HTTP 200" >&2
  exit 1
fi

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
if ! jwt_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert "$route_ca_file" \
  --connect-to "$jwt_hostname:443:$router_hostname:443" \
  --header "Host: $jwt_hostname" \
  --header "Authorization: Bearer $jwt" \
  "https://$jwt_hostname/inventory"); then
  echo "error: JWT endpoint request failed before receiving an HTTP response" >&2
  exit 1
fi
echo "JWT request -> HTTP $jwt_status (expected 200)"
if [[ $jwt_status != "200" ]]; then
  echo "error: authenticated JWT request did not return HTTP 200" >&2
  exit 1
fi

echo "demo complete: authentication, Free-tier 429, live upgrade, and JWT validation were exercised"
