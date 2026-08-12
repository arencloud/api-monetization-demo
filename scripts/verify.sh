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
  api-monetization-grafana-operator \
  api-monetization-observability \
  api-monetization-console-plugins; do
  wait_for_application "$application_name"
done

echo "waiting for generated credentials"
oc wait --for=condition=Ready secretstore/api-monetization-identity \
  -n api-monetization-observability --timeout=5m
oc wait --for=condition=Ready externalsecret/keycloak-db-credentials \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/keycloak-demo-clients \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/monetization-portal-credentials \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/monetization-developer-credentials \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/grafana-keycloak-client \
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

echo "validating JWT identity-to-subscription resolution"
keycloak_hostname=$(oc get route api-monetization-keycloak \
  -n api-monetization-identity -o jsonpath='{.status.ingress[0].host}')
keycloak_router_hostname=$(oc get route api-monetization-keycloak \
  -n api-monetization-identity -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
keycloak_client_secret=$(oc get secret keycloak-demo-clients \
  -n api-monetization-identity \
  -o go-template='{{index .data "free-client-secret"}}' | base64 -d)
jwt_token=$(curl --silent --show-error --fail \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
  --user "demo-free-client:$keycloak_client_secret" \
  --data 'grant_type=client_credentials' \
  "https://$keycloak_hostname/realms/api-monetization/protocol/openid-connect/token" \
  | jq -er '.access_token')
jwt_authenticated_status=$(curl --silent --show-error --output /dev/null \
  --write-out '%{http_code}' \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$jwt_hostname:443:$router_hostname:443" \
  --header "Host: $jwt_hostname" \
  --header "Authorization: Bearer $jwt_token" \
  "https://$jwt_hostname/inventory")
case "$jwt_authenticated_status" in
  200)
    echo "JWT identity resolved to the active PostgreSQL subscription"
    ;;
  429)
    echo "JWT identity resolved correctly but its active plan window is already rate-limited"
    ;;
  *)
    echo "error: authenticated JWT request returned HTTP $jwt_authenticated_status" >&2
    exit 1
    ;;
esac

echo "validating the Keycloak-protected monetization portal"
for permission in \
  'create|apikeys.devportal.kuadrant.io' \
  'delete|apikeys.devportal.kuadrant.io' \
  'create|passwords.generators.external-secrets.io' \
  'delete|passwords.generators.external-secrets.io' \
  'create|externalsecrets.external-secrets.io' \
  'delete|externalsecrets.external-secrets.io' \
  'get|secrets' \
  'delete|secrets'; do
  IFS='|' read -r verb resource <<<"$permission"
  if [[ $(oc auth can-i "$verb" "$resource" -n api-monetization-apps \
      --as=system:serviceaccount:api-monetization-data:monetization-control) != "yes" ]]; then
    echo "error: monetization control service cannot $verb $resource for self-service provisioning" >&2
    exit 1
  fi
done
portal_hostname=$(oc get route monetization-control -n api-monetization-data \
  -o jsonpath='{.status.ingress[0].host}')
portal_router_hostname=$(oc get route monetization-control -n api-monetization-data \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
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
invoice_history=$(curl --silent --show-error --fail \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$portal_hostname:443:$portal_router_hostname:443" \
  --header "Authorization: Bearer $portal_token" \
  "https://$portal_hostname/api/invoices")
if ! jq -e 'type == "array"' <<<"$invoice_history" >/dev/null; then
  echo "error: administrator invoice API did not return invoice history" >&2
  exit 1
fi
developer_token=$(CONTROL_TOKEN_CLIENT_ID=monetization-developer-automation \
  CONTROL_TOKEN_SECRET_NAME=monetization-developer-credentials \
  CONTROL_TOKEN_SECRET_KEY=developer-automation-client-secret \
  CONTROL_TOKEN_LOCAL_PORT=18085 \
  "$(dirname "${BASH_SOURCE[0]}")/control-token.sh")
developer_identity=$(curl --silent --show-error --fail \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$portal_hostname:443:$portal_router_hostname:443" \
  --header "Authorization: Bearer $developer_token" \
  "https://$portal_hostname/api/me")
if ! jq -e '.developer == true and .admin == false' <<<"$developer_identity" >/dev/null; then
  echo "error: developer automation identity does not have the expected portal role" >&2
  exit 1
fi
developer_catalog=$(curl --silent --show-error --fail \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$portal_hostname:443:$portal_router_hostname:443" \
  --header "Authorization: Bearer $developer_token" \
  "https://$portal_hostname/api/catalog")
if ! jq -e 'any(.products[]; .id == "inventory" and .available == true)' \
  <<<"$developer_catalog" >/dev/null; then
  echo "error: developer catalog does not expose the Inventory API" >&2
  exit 1
fi
echo "Portal: https://$portal_hostname (OIDC discovery, role boundary, and invoice API verified)"
echo "Developer self-service identity and Inventory API catalog verified"

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

echo "waiting for the operator-managed Grafana dashboard"
oc wait --for=condition=Ready externalsecret/api-monetization-grafana-admin \
  -n api-monetization-observability --timeout=5m
oc wait --for=condition=Ready externalsecret/api-monetization-grafana-oauth \
  -n api-monetization-observability --timeout=5m
oc wait --for=condition=GrafanaReady \
  grafanas.grafana.integreatly.org/api-monetization-grafana \
  -n api-monetization-observability --timeout=10m
oc wait --for=condition=DatasourceSynchronized \
  grafanadatasources.grafana.integreatly.org/api-monetization-thanos \
  -n api-monetization-observability --timeout=5m
oc wait --for=condition=DashboardSynchronized \
  grafanadashboards.grafana.integreatly.org/api-monetization \
  -n api-monetization-observability --timeout=5m
oc rollout status deployment/api-monetization-grafana-deployment \
  -n api-monetization-observability --timeout=10m
oc wait route/api-monetization-grafana-route \
  -n api-monetization-observability \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m
grafana_hostname=$(oc get route api-monetization-grafana-route \
  -n api-monetization-observability -o jsonpath='{.status.ingress[0].host}')
grafana_router_hostname=$(oc get route api-monetization-grafana-route \
  -n api-monetization-observability \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
grafana_root_url=$(oc get configmap api-monetization-grafana-oauth-config \
  -n api-monetization-observability -o jsonpath='{.data.grafana-root-url}')
grafana_keycloak_origin=$(oc get configmap api-monetization-grafana-oauth-config \
  -n api-monetization-observability -o jsonpath='{.data.keycloak-origin}')
if [[ $grafana_root_url != "https://$grafana_hostname" || \
  $grafana_keycloak_origin != "https://$keycloak_hostname" ]]; then
  echo "error: Grafana OAuth origin discovery does not match the admitted Routes" >&2
  exit 1
fi
source_oauth_secret=$(oc get secret grafana-keycloak-client \
  -n api-monetization-identity -o jsonpath='{.data.client-secret}')
mirrored_oauth_secret=$(oc get secret api-monetization-grafana-oauth \
  -n api-monetization-observability -o jsonpath='{.data.client-secret}')
if [[ -z $source_oauth_secret || $source_oauth_secret != "$mirrored_oauth_secret" ]]; then
  echo "error: Grafana OAuth client secret was not replicated from the identity namespace" >&2
  exit 1
fi

keycloak_admin=$(oc get secret api-monetization-initial-admin \
  -n api-monetization-identity \
  -o go-template='{{index .data "username"}}' | base64 -d)
keycloak_admin_password=$(oc get secret api-monetization-initial-admin \
  -n api-monetization-identity \
  -o go-template='{{index .data "password"}}' | base64 -d)
keycloak_admin_token=$(curl --silent --show-error --fail \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
  --data-urlencode "username=$keycloak_admin" \
  --data-urlencode "password=$keycloak_admin_password" \
  --data 'client_id=admin-cli' \
  --data 'grant_type=password' \
  "https://$keycloak_hostname/realms/master/protocol/openid-connect/token" \
  | jq -er '.access_token')
grafana_client=$(curl --silent --show-error --fail \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
  --header "Authorization: Bearer $keycloak_admin_token" \
  "https://$keycloak_hostname/admin/realms/api-monetization/clients?clientId=api-monetization-grafana")
grafana_callback="https://$grafana_hostname/login/generic_oauth"
if ! jq -e --arg callback "$grafana_callback" '
  length == 1 and
  .[0].publicClient == false and
  .[0].standardFlowEnabled == true and
  .[0].directAccessGrantsEnabled == false and
  (.[0].redirectUris | index($callback) != null) and
  any(.[0].protocolMappers[];
    .protocolMapper == "oidc-usermodel-realm-role-mapper" and
    .config["claim.name"] == "roles" and
    .config["access.token.claim"] == "true" and
    .config["id.token.claim"] == "true" and
    .config["userinfo.token.claim"] == "true")
' <<<"$grafana_client" >/dev/null; then
  echo "error: Keycloak Grafana client or realm-role mapper is incomplete" >&2
  exit 1
fi

grafana_oauth_headers=$(curl --silent --show-error \
  --output /dev/null --dump-header - \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$grafana_hostname:443:$grafana_router_hostname:443" \
  "https://$grafana_hostname/login/generic_oauth")
grafana_oauth_status=$(awk 'NR == 1 {print $2}' <<<"$grafana_oauth_headers")
grafana_oauth_location=$(awk 'tolower($1) == "location:" {$1=""; sub(/^ /, ""); print}' \
  <<<"$grafana_oauth_headers" | tr -d '\r' | tail -n 1)
if [[ $grafana_oauth_status != "302" || \
  $grafana_oauth_location != *"$keycloak_hostname/realms/api-monetization/protocol/openid-connect/auth"* || \
  $grafana_oauth_location != *"client_id=api-monetization-grafana"* ]]; then
  echo "error: Grafana generic OAuth login did not redirect to the expected Keycloak client" >&2
  exit 1
fi

grafana_password=$(oc get secret api-monetization-grafana-admin \
  -n api-monetization-observability \
  -o go-template='{{index .data "GF_SECURITY_ADMIN_PASSWORD"}}' | base64 -d)
grafana_dashboard=$(curl --silent --show-error --fail \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$grafana_hostname:443:$grafana_router_hostname:443" \
  --user "admin:$grafana_password" \
  "https://$grafana_hostname/api/dashboards/uid/api-monetization")
if [[ $(jq -r '.dashboard.uid' <<<"$grafana_dashboard") != "api-monetization" ]]; then
  echo "error: Grafana did not return the managed API Monetization dashboard" >&2
  exit 1
fi
grafana_datasource_health=$(curl --silent --show-error --fail \
  --cacert <(oc get secret "$ingress_certificate" -n openshift-ingress \
    -o go-template='{{index .data "tls.crt"}}' | base64 -d) \
  --connect-to "$grafana_hostname:443:$grafana_router_hostname:443" \
  --user "admin:$grafana_password" \
  "https://$grafana_hostname/api/datasources/uid/openshift-thanos/health")
grafana_datasource_status=$(jq -r '.status | ascii_downcase' <<<"$grafana_datasource_health")
if [[ $grafana_datasource_status != "ok" && $grafana_datasource_status != "success" ]]; then
  echo "error: Grafana OpenShift Thanos datasource health check failed" >&2
  jq . <<<"$grafana_datasource_health" >&2
  exit 1
fi
echo "Grafana: https://$grafana_hostname/d/api-monetization (Keycloak SSO, role mapping, dashboard, and Thanos datasource verified)"

echo "API monetization platform verification passed"
