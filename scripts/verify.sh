#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

wait_for_application() {
  local application_name=$1
  local state=""

  for _ in $(seq 1 270); do
    state=$(oc get application "$application_name" -n openshift-gitops \
      -o jsonpath='{.status.sync.status}{"|"}{.status.health.status}' \
      2>/dev/null || true)
    if [[ $state == "Synced|Healthy" ]]; then
      echo "$application_name is Synced and Healthy"
      return 0
    fi
    sleep 10
  done

  echo "error: $application_name did not become Synced and Healthy (last state: ${state:-not created})" >&2
  return 1
}

wait_for_image_stream_tag() {
  local tag_name=$1
  local namespace=$2
  local image_reference=""

  for _ in $(seq 1 180); do
    image_reference=$(oc get imagestreamtag.image.openshift.io "$tag_name" \
      -n "$namespace" -o jsonpath='{.image.dockerImageReference}' \
      2>/dev/null || true)
    if [[ -n $image_reference ]]; then
      echo "$tag_name is available as $image_reference"
      return 0
    fi
    sleep 5
  done

  echo "error: ImageStreamTag $namespace/$tag_name did not become available" >&2
  return 1
}

wait_for_http_route() {
  local route_name=$1
  local namespace=$2
  local generation=""
  local accepted=""

  for _ in $(seq 1 120); do
    generation=$(oc get httproute.gateway.networking.k8s.io "$route_name" \
      -n "$namespace" -o jsonpath='{.metadata.generation}' \
      2>/dev/null || true)
    accepted=$(oc get httproute.gateway.networking.k8s.io "$route_name" \
      -n "$namespace" \
      -o jsonpath='{range .status.parents[?(@.controllerName=="istio.io/gateway-controller")].conditions[?(@.type=="Accepted")]}{.status}{"|"}{.observedGeneration}{end}' \
      2>/dev/null || true)
    if [[ -n $generation && $accepted == "True|$generation" ]]; then
      echo "HTTPRoute $namespace/$route_name is Accepted"
      return 0
    fi
    sleep 5
  done

  echo "error: HTTPRoute $namespace/$route_name was not accepted (last condition: ${accepted:-not reported})" >&2
  return 1
}

echo "waiting for GitOps applications"
for application_name in \
  api-monetization-namespaces \
  api-monetization-external-secrets \
  api-monetization-demo-secrets \
  api-monetization-database \
  api-monetization-identity \
  api-monetization-inventory \
  api-monetization-control \
  api-monetization-service-mesh \
  api-monetization-connectivity-link \
  api-monetization-gateway \
  api-monetization-observability \
  api-monetization-console-plugins; do
  wait_for_application "$application_name"
done

echo "waiting for generated credentials"
oc wait --for=condition=Ready externalsecret/keycloak-db-credentials \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/keycloak-demo-clients \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/monetization-portal-credentials \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/subscriptions-db-credentials \
  -n api-monetization-data --timeout=5m
oc wait --for=condition=Ready externalsecret/demo-inventory-api-key \
  -n api-monetization-apps --timeout=5m

echo "waiting for PostgreSQL clusters"
oc wait --for=condition=Ready clusters.postgresql.cnpg.io/keycloak-postgres \
  -n api-monetization-identity --timeout=10m
oc wait --for=condition=Ready clusters.postgresql.cnpg.io/subscriptions-postgres \
  -n api-monetization-data --timeout=10m

echo "waiting for Red Hat build of Keycloak"
oc wait --for=condition=Ready keycloaks.k8s.keycloak.org/api-monetization \
  -n api-monetization-identity --timeout=10m
oc wait --for=condition=Done keycloakrealmimports.k8s.keycloak.org/api-monetization-realm \
  -n api-monetization-identity --timeout=10m
oc wait route/api-monetization-keycloak -n api-monetization-identity \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m

echo "waiting for application builds and workloads"
oc wait clusteroperator/image-registry --for=condition=Available --timeout=10m
wait_for_image_stream_tag inventory-api:demo api-monetization-apps
wait_for_image_stream_tag monetization-control:demo api-monetization-data
oc rollout status deployment/inventory-api -n api-monetization-apps --timeout=10m
oc rollout status deployment/monetization-control -n api-monetization-data --timeout=10m
oc wait route/monetization-control -n api-monetization-data \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m

echo "waiting for gateway, routes, policies, and catalog resources"
oc wait --for=condition=Ready kuadrants.kuadrant.io/kuadrant \
  -n kuadrant-system --timeout=10m
oc wait --for=condition=Ready authorinos.operator.authorino.kuadrant.io/authorino \
  -n kuadrant-system --timeout=10m
oc wait --for=condition=Ready limitadors.limitador.kuadrant.io/limitador \
  -n kuadrant-system --timeout=10m
oc wait --for=condition=Programmed gateways.gateway.networking.k8s.io/api-monetization \
  -n api-monetization-gateway --timeout=10m
gateway_class=$(oc get gateway api-monetization -n api-monetization-gateway \
  -o jsonpath='{.spec.gatewayClassName}')
gateway_controller=$(oc get gatewayclass "$gateway_class" \
  -o jsonpath='{.spec.controllerName}')
if [[ $gateway_class != "istio" || $gateway_controller != "istio.io/gateway-controller" ]]; then
  echo "error: Gateway is not controlled by the project Service Mesh" >&2
  exit 1
fi
peer_mtls=$(oc get peerauthentication.security.istio.io default \
  -n api-monetization-apps -o jsonpath='{.spec.mtls.mode}')
if [[ $peer_mtls != "STRICT" ]]; then
  echo "error: application Service Mesh mTLS mode is not STRICT" >&2
  exit 1
fi
if oc get destinationrule.networking.istio.io/inventory-api-cross-mesh \
  -n api-monetization-gateway >/dev/null 2>&1; then
  echo "error: obsolete cross-mesh plaintext exception still exists" >&2
  exit 1
fi
gateway_service=$(oc get services -n api-monetization-gateway \
  -l gateway.networking.k8s.io/gateway-name=api-monetization,gateway.networking.k8s.io/gateway-class-name=istio \
  -o jsonpath='{.items[0].metadata.name}')
gateway_service_type=$(oc get service "$gateway_service" -n api-monetization-gateway \
  -o jsonpath='{.spec.type}')
case "$gateway_service_type" in
  LoadBalancer)
    gateway_external_address=$(oc get service "$gateway_service" \
      -n api-monetization-gateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')
    if [[ -z $gateway_external_address ]]; then
      echo "error: Gateway Service is LoadBalancer but has no external address" >&2
      exit 1
    fi
    echo "Gateway Service mode: LoadBalancer ($gateway_external_address)"
    ;;
  ClusterIP)
    echo "Gateway Service mode: ClusterIP through OpenShift Routes"
    ;;
  *)
    echo "error: unsupported Gateway Service type: $gateway_service_type" >&2
    exit 1
    ;;
esac
gateway_proxy=$(oc get pods -n api-monetization-gateway \
  -l gateway.networking.k8s.io/gateway-name=api-monetization \
  -o jsonpath='{range .items[*].spec.initContainers[*]}{.name}{"\n"}{end}{range .items[*].spec.containers[*]}{.name}{"\n"}{end}' \
  | grep -Fx istio-proxy | head -n 1 || true)
inventory_proxy=$(oc get pods -n api-monetization-apps \
  -l app.kubernetes.io/name=inventory-api \
  -o jsonpath='{range .items[*].spec.initContainers[*]}{.name}{"\n"}{end}{range .items[*].spec.containers[*]}{.name}{"\n"}{end}' \
  | grep -Fx istio-proxy | head -n 1 || true)
if [[ $gateway_proxy != "istio-proxy" || $inventory_proxy != "istio-proxy" ]]; then
  echo "error: Gateway or Inventory workload is missing its Service Mesh proxy" >&2
  exit 1
fi
oc wait route/api-monetization -n api-monetization-gateway \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m
oc wait route/api-monetization-jwt -n api-monetization-gateway \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m
for route_name in api-monetization api-monetization-jwt; do
  route_service=$(oc get route "$route_name" -n api-monetization-gateway \
    -o jsonpath='{.spec.to.name}')
  if [[ $route_service != "$gateway_service" ]]; then
    echo "error: Route $route_name targets $route_service instead of $gateway_service" >&2
    exit 1
  fi
done
wait_for_http_route inventory-api-key api-monetization-apps
wait_for_http_route inventory-jwt api-monetization-apps
for policy in inventory-api-key inventory-jwt; do
  oc wait --for=condition=Enforced "authpolicies.kuadrant.io/$policy" \
    -n api-monetization-apps --timeout=5m
done
oc wait --for=condition=Enforced ratelimitpolicies.kuadrant.io/inventory-jwt-plans \
  -n api-monetization-apps --timeout=5m
oc wait --for=condition=Enforced planpolicies.extensions.kuadrant.io/inventory-api-plans \
  -n api-monetization-apps --timeout=5m
oc wait --for=condition=Approved apikeys.devportal.kuadrant.io/demo-inventory-key \
  -n api-monetization-apps --timeout=5m

api_hostname=$(oc get route api-monetization -n api-monetization-gateway \
  -o jsonpath='{.status.ingress[0].host}')
jwt_hostname=$(oc get route api-monetization-jwt -n api-monetization-gateway \
  -o jsonpath='{.status.ingress[0].host}')
api_route_hostname=$(oc get httproute inventory-api-key -n api-monetization-apps \
  -o jsonpath='{.spec.hostnames[0]}')
jwt_route_hostname=$(oc get httproute inventory-jwt -n api-monetization-apps \
  -o jsonpath='{.spec.hostnames[0]}')
if [[ $api_hostname != "$api_route_hostname" || $jwt_hostname != "$jwt_route_hostname" ]]; then
  echo "error: OpenShift Route and Gateway API HTTPRoute hostnames do not match" >&2
  exit 1
fi

echo "waiting for the APIProduct to publish the admitted API URL"
for _ in $(seq 1 60); do
  api_product_state=$(oc get apiproduct inventory-api -n api-monetization-apps \
    -o jsonpath='{.metadata.generation}{"|"}{.status.observedGeneration}' 2>/dev/null || true)
  api_product_server=$(oc get apiproduct inventory-api -n api-monetization-apps \
    -o jsonpath='{.status.openapi.raw}' 2>/dev/null \
    | sed -n 's/^  - url: //p' | head -n 1) || true
  if [[ $api_product_state == *"|"* ]]; then
    IFS='|' read -r api_product_generation api_product_observed_generation \
      <<<"$api_product_state"
    if [[ $api_product_generation == "$api_product_observed_generation" && \
      $api_product_server == "https://$api_hostname" ]]; then
      break
    fi
  fi
  sleep 5
done
if [[ ${api_product_server:-} != "https://$api_hostname" ]]; then
  echo "error: APIProduct does not publish the admitted API URL" >&2
  exit 1
fi
echo "API-key endpoint: https://$api_hostname/inventory"
echo "JWT endpoint: https://$jwt_hostname/inventory"

echo "validating authenticated traffic through the complete data path"
router_hostname=$(oc get route api-monetization -n api-monetization-gateway \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
ingress_certificate=$(oc get ingresscontroller.operator.openshift.io default \
  -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
if [[ -z $ingress_certificate ]]; then
  ingress_certificate=router-certs-default
fi
api_key_secret=$(oc get apikey demo-inventory-key -n api-monetization-apps \
  -o jsonpath='{.spec.secretRef.name}')
api_key_value=$(oc get secret "$api_key_secret" -n api-monetization-apps \
  -o go-template='{{index .data "api_key"}}' | base64 -d)
api_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$api_hostname:443:$router_hostname:443" \
  --header "Authorization: APIKEY $api_key_value" \
  "https://$api_hostname/inventory")
case "$api_status" in
  200)
    echo "authenticated data-path request returned HTTP 200 through enforced same-mesh mTLS"
    ;;
  429)
    echo "authenticated data-path request was rate-limited; wait for the active plan window to expire before an end-to-end retest"
    ;;
  *)
    echo "error: authenticated data-path request returned HTTP $api_status" >&2
    exit 1
    ;;
esac

echo "validating the JWT endpoint TLS identity"
jwt_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$jwt_hostname:443:$router_hostname:443" \
  --header "Host: $jwt_hostname" \
  "https://$jwt_hostname/inventory")
if [[ $jwt_status != "401" ]]; then
  echo "error: unauthenticated JWT endpoint request returned HTTP $jwt_status instead of 401" >&2
  exit 1
fi
echo "JWT endpoint certificate is valid and unauthenticated traffic returned HTTP 401"

echo "validating the Keycloak-protected monetization portal"
portal_hostname=$(oc get route monetization-control -n api-monetization-data \
  -o jsonpath='{.status.ingress[0].host}')
portal_router_hostname=$(oc get route monetization-control -n api-monetization-data \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
keycloak_hostname=$(oc get route api-monetization-keycloak \
  -n api-monetization-identity -o jsonpath='{.status.ingress[0].host}')
portal_config=$(curl --silent --show-error --fail \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$portal_hostname:443:$portal_router_hostname:443" \
  "https://$portal_hostname/api/config")
if [[ $(jq -r '.clientId' <<<"$portal_config") != "monetization-portal" || \
  $(jq -r '.issuerUrl' <<<"$portal_config") != "https://$keycloak_hostname/realms/api-monetization" ]]; then
  echo "error: portal OIDC discovery does not match the admitted Keycloak Route" >&2
  exit 1
fi
portal_unauthenticated=$(curl --silent --show-error --output /dev/null \
  --write-out '%{http_code}' \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$portal_hostname:443:$portal_router_hostname:443" \
  "https://$portal_hostname/api/subscriptions")
if [[ $portal_unauthenticated != "401" ]]; then
  echo "error: unauthenticated portal API returned HTTP $portal_unauthenticated instead of 401" >&2
  exit 1
fi
portal_token=$("$(dirname "${BASH_SOURCE[0]}")/control-token.sh")
portal_authorized=$(curl --silent --show-error --output /dev/null \
  --write-out '%{http_code}' \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$portal_hostname:443:$portal_router_hostname:443" \
  --header "Authorization: Bearer $portal_token" \
  "https://$portal_hostname/api/subscriptions")
if [[ $portal_authorized != "200" ]]; then
  echo "error: administrator portal API returned HTTP $portal_authorized instead of 200" >&2
  exit 1
fi
echo "Portal: https://$portal_hostname (OIDC discovery, 401 boundary, and administrator role verified)"

echo "waiting for operator console plugins"
for plugin in gitops-plugin kuadrant-console-plugin; do
  oc get consoleplugin.console.openshift.io "$plugin" >/dev/null
  if ! oc get console.operator.openshift.io cluster \
    -o jsonpath='{.spec.plugins}' | grep -qw "$plugin"; then
    echo "error: Console plugin $plugin is installed but not enabled" >&2
    exit 1
  fi
done
oc wait clusteroperator/console --for=condition=Available=True --timeout=10m
oc wait clusteroperator/console --for=condition=Progressing=False --timeout=10m

echo "waiting for tracing and telemetry collection"
oc wait --for=condition=Ready tempomonolithics.tempo.grafana.com/api-monetization \
  -n api-monetization-observability --timeout=10m
oc rollout status deployment/api-monetization-collector \
  -n api-monetization-observability --timeout=10m

echo "API monetization platform verification passed"
