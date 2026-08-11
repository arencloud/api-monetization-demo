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
gitops_namespace=openshift-gitops
gitops_application=api-monetization-gateway
control_port=${CONTROL_LOCAL_PORT:-18080}
keycloak_port=${KEYCLOAK_LOCAL_PORT:-18081}
control_token_port=${CONTROL_TOKEN_LOCAL_PORT:-18083}
control_internal_port=${CONTROL_INTERNAL_LOCAL_PORT:-18084}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
port_forward_pids=()
route_ca_file=""

if [[ $control_port == "$keycloak_port" ||
  $control_port == "$control_token_port" ||
  $control_port == "$control_internal_port" ||
  $keycloak_port == "$control_token_port" ||
  $keycloak_port == "$control_internal_port" ||
  $control_token_port == "$control_internal_port" ]]; then
  echo "error: demo local port settings must be unique" >&2
  echo "CONTROL_LOCAL_PORT=$control_port KEYCLOAK_LOCAL_PORT=$keycloak_port CONTROL_TOKEN_LOCAL_PORT=$control_token_port CONTROL_INTERNAL_LOCAL_PORT=$control_internal_port" >&2
  exit 1
fi

cleanup() {
  for pid in "${port_forward_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  if [[ -n $route_ca_file ]]; then
    rm -f "$route_ca_file"
  fi
}
trap cleanup EXIT

wait_for_jwt_policy_revision() {
  local app_sync
  local auth_policy
  local rate_limit_policy

  echo "waiting for GitOps to apply and enforce the current JWT monetization policy"
  for _ in $(seq 1 120); do
    app_sync=$(oc get application "$gitops_application" -n "$gitops_namespace" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    auth_policy=$(oc get authpolicy inventory-jwt -n "$application_namespace" \
      -o json 2>/dev/null || true)
    rate_limit_policy=$(oc get ratelimitpolicy inventory-jwt-plans \
      -n "$application_namespace" -o json 2>/dev/null || true)

    if [[ $app_sync == "Synced" ]] && \
      jq -e '
        .spec.rules.metadata.subscription.http.urlExpression
          | contains("/internal/entitlements/token/") and
            contains("auth.identity.sub") and
            contains("auth.identity.azp")
      ' <<<"$auth_policy" >/dev/null 2>&1 && \
      jq -e '
        .spec.rules.response.success.filters.kuadrant.json.properties.customer.selector == "auth.metadata.subscription.customerId" and
        .spec.rules.response.success.filters.kuadrant.json.properties.plan.selector == "auth.metadata.subscription.plan" and
        .status.observedGeneration == .metadata.generation and
        any(.status.conditions[]?; .type == "Enforced" and .status == "True")
      ' <<<"$auth_policy" >/dev/null 2>&1 && \
      jq -e '
        .spec.limits.free.counters[0].expression == "auth.kuadrant.customer" and
        .spec.limits.free.when[0].predicate == "auth.kuadrant.plan == \"free\"" and
        .spec.limits.developer.counters[0].expression == "auth.kuadrant.customer" and
        .spec.limits.developer.when[0].predicate == "auth.kuadrant.plan == \"developer\"" and
        .spec.limits.business.counters[0].expression == "auth.kuadrant.customer" and
        .spec.limits.business.when[0].predicate == "auth.kuadrant.plan == \"business\"" and
        .status.observedGeneration == .metadata.generation and
        any(.status.conditions[]?; .type == "Enforced" and .status == "True")
      ' <<<"$rate_limit_policy" >/dev/null 2>&1; then
      echo "current JWT monetization policy is synced and enforced"
      return 0
    fi
    sleep 5
  done

  echo "error: current JWT monetization policy was not synced and enforced within 10 minutes" >&2
  echo "check Argo CD application $gitops_application before retrying" >&2
  return 1
}

wait_for_jwt_policy_revision

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

echo "starting the monetization control plane tunnel"
oc port-forward -n "$data_namespace" service/monetization-control \
  "$control_port:8080" "$control_internal_port:8081" \
  >/tmp/api-monetization-control-port-forward.log 2>&1 &
port_forward_pids+=("$!")
for _ in $(seq 1 30); do
  curl --silent --fail "http://127.0.0.1:$control_port/readyz" >/dev/null && break
  sleep 1
done
control_token=$(CONTROL_TOKEN_LOCAL_PORT="$control_token_port" \
  "$script_dir/control-token.sh")
subscription_plan=$(curl --silent --show-error --fail \
  --header "Authorization: Bearer $control_token" \
  "http://127.0.0.1:$control_port/api/subscriptions" \
  | jq -r '.[] | select(.customerId == "demo-company" and .product == "inventory") | .plan')
if [[ $subscription_plan != "free" ]]; then
  echo "error: demo-company Inventory subscription is on the ${subscription_plan:-unknown} plan; run 'make reset-demo', wait 60 seconds, and retry" >&2
  exit 1
fi

echo "waiting for the shared JWT subscription entitlement"
identity_entitlement=""
for _ in $(seq 1 120); do
  if identity_entitlement=$(curl --silent --show-error --fail \
      "http://127.0.0.1:$control_internal_port/internal/entitlements/identity/keycloak-client/demo-free-client/inventory" \
      2>/dev/null) && \
    jq -e '.customerId == "demo-company" and .product == "inventory" and .plan == "free"' \
      <<<"$identity_entitlement" >/dev/null 2>&1; then
    break
  fi
  identity_entitlement=""
  sleep 5
done
if [[ -z $identity_entitlement ]]; then
  echo "error: shared JWT subscription entitlement did not become ready within 10 minutes" >&2
  echo "check Argo CD application api-monetization-control before retrying" >&2
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

keycloak_host=api-monetization-service.api-monetization-identity.svc.cluster.local
oc port-forward -n api-monetization-identity service/api-monetization-service \
  "$keycloak_port:8080" >/tmp/api-monetization-keycloak-port-forward.log 2>&1 &
port_forward_pids+=("$!")
client_secret=$(oc get secret keycloak-demo-clients -n api-monetization-identity \
  -o go-template='{{index .data "free-client-secret"}}' | base64 -d)

issue_jwt() {
  local token_response
  token_response=$(curl --silent --show-error --fail \
    --connect-to "$keycloak_host:8080:127.0.0.1:$keycloak_port" \
    --user "demo-free-client:$client_secret" \
    --data 'grant_type=client_credentials' \
    "http://$keycloak_host:8080/realms/api-monetization/protocol/openid-connect/token")
  jq -er '.access_token' <<<"$token_response"
}

jwt_client_id() {
  local token=$1
  local payload=${token#*.}
  payload=${payload%%.*}
  case $((${#payload} % 4)) in
    0) ;;
    2) payload+="==" ;;
    3) payload+="=" ;;
    *) return 1 ;;
  esac
  printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -er '.azp'
}

request_jwt() {
  local token=$1
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert "$route_ca_file" \
    --connect-to "$jwt_hostname:443:$router_hostname:443" \
    --header "Host: $jwt_hostname" \
    --header "Authorization: Bearer $token" \
    "https://$jwt_hostname/inventory"
}

for _ in $(seq 1 30); do
  if subscription_jwt=$(issue_jwt 2>/dev/null); then
    break
  fi
  sleep 1
done
if [[ ${subscription_jwt:-} == "" || $(jwt_client_id "$subscription_jwt") != "demo-free-client" ]]; then
  echo "error: Keycloak did not issue the expected demo-free-client JWT" >&2
  exit 1
fi

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

echo "Keycloak JWT Free burst: 12 requests against the same subscription's 10/minute limit"
jwt_successful_requests=0
jwt_limited_requests=0
for request_number in $(seq 1 12); do
  jwt_status=$(request_jwt "$subscription_jwt")
  echo "Free JWT request $request_number -> HTTP $jwt_status"
  case "$jwt_status" in
    200) jwt_successful_requests=$((jwt_successful_requests + 1)) ;;
    429) jwt_limited_requests=$((jwt_limited_requests + 1)) ;;
    *)
      echo "error: Free JWT request returned unexpected HTTP $jwt_status" >&2
      exit 1
      ;;
  esac
done
if ((jwt_successful_requests == 0 || jwt_limited_requests == 0)); then
  echo "error: Free JWT burst did not demonstrate both accepted and rate-limited requests; run 'make reset-demo', wait 60 seconds, and retry" >&2
  exit 1
fi

echo "upgrading demo-company from Free to Developer"
upgrade_response=$(curl --silent --fail-with-body \
  --header "Authorization: Bearer $control_token" \
  --header 'content-type: application/json' \
  --data '{"plan":"developer"}' \
  "http://127.0.0.1:$control_port/api/subscriptions/demo-company/plan")
jq . <<<"$upgrade_response"
if [[ $(jq -r '.plan' <<<"$upgrade_response") != "developer" ]]; then
  echo "error: control plane did not return the Developer subscription" >&2
  exit 1
fi

echo "Developer plan continuation burst: 12 requests against the 1,000/minute limit"
for request_number in $(seq 1 12); do
  upgraded_status=$(request_api_key)
  echo "Developer request $request_number -> HTTP $upgraded_status (expected 200)"
  if [[ $upgraded_status != "200" ]]; then
    echo "error: Developer request $request_number did not return HTTP 200" >&2
    exit 1
  fi
done

echo "same Keycloak JWT after the shared upgrade: 12 requests against the 1,000/minute limit"
for request_number in $(seq 1 12); do
  jwt_status=$(request_jwt "$subscription_jwt")
  echo "Developer JWT request $request_number -> HTTP $jwt_status (expected 200)"
  if [[ $jwt_status != "200" ]]; then
    echo "error: Developer JWT request $request_number did not return HTTP 200" >&2
    exit 1
  fi
done

echo "demo complete: one subscription upgrade changed API-key and Keycloak JWT limits immediately without replacing the JWT"
