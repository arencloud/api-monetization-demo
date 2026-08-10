#!/usr/bin/env bash

set -Eeuo pipefail

echo "waiting for generated credentials"
oc wait --for=condition=Ready externalsecret/keycloak-db-credentials \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/keycloak-demo-clients \
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

echo "waiting for application builds and workloads"
oc wait clusteroperator/image-registry --for=condition=Available --timeout=10m
oc wait --for=jsonpath='{.image.dockerImageReference}' \
  imagestreamtags.image.openshift.io/inventory-api:demo \
  -n api-monetization-apps --timeout=15m
oc wait --for=jsonpath='{.image.dockerImageReference}' \
  imagestreamtags.image.openshift.io/monetization-control:demo \
  -n api-monetization-data --timeout=15m
oc rollout status deployment/inventory-api -n api-monetization-apps --timeout=10m
oc rollout status deployment/monetization-control -n api-monetization-data --timeout=10m

echo "waiting for gateway, routes, policies, and catalog resources"
oc wait --for=condition=Ready kuadrants.kuadrant.io/kuadrant \
  -n kuadrant-system --timeout=10m
oc wait --for=condition=Ready authorinos.operator.authorino.kuadrant.io/authorino \
  -n kuadrant-system --timeout=10m
oc wait --for=condition=Ready limitadors.limitador.kuadrant.io/limitador \
  -n kuadrant-system --timeout=10m
oc wait --for=condition=Programmed gateways.gateway.networking.k8s.io/api-monetization \
  -n api-monetization-gateway --timeout=10m
gateway_service=$(oc get services -n api-monetization-gateway \
  -l gateway.networking.k8s.io/gateway-name=api-monetization \
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
oc wait route/api-monetization -n api-monetization-gateway \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m
oc wait route/api-monetization-jwt -n api-monetization-gateway \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m
oc wait --for=condition=Accepted httproutes.gateway.networking.k8s.io/inventory-api-key \
  -n api-monetization-apps --timeout=5m
oc wait --for=condition=Accepted httproutes.gateway.networking.k8s.io/inventory-jwt \
  -n api-monetization-apps --timeout=5m
for policy in inventory-api-key inventory-jwt; do
  oc wait --for=condition=Enforced "authpolicies.kuadrant.io/$policy" \
    -n api-monetization-apps --timeout=5m
done
oc wait --for=condition=Enforced ratelimitpolicies.kuadrant.io/inventory-jwt-plans \
  -n api-monetization-apps --timeout=5m
oc wait --for=condition=Enforced planpolicies.extensions.kuadrant.io/inventory-api-plans \
  -n api-monetization-apps --timeout=5m
oc wait --for=condition=Ready apikeys.devportal.kuadrant.io/demo-inventory-key \
  -n api-monetization-apps --timeout=5m

echo "waiting for tracing and telemetry collection"
oc wait --for=condition=Ready tempomonolithics.tempo.grafana.com/api-monetization \
  -n api-monetization-observability --timeout=10m
oc rollout status deployment/api-monetization-collector \
  -n api-monetization-observability --timeout=10m

echo "API monetization platform verification passed"
