#!/usr/bin/env bash

set -Eeuo pipefail

echo "waiting for generated credentials"
oc wait --for=condition=Ready externalsecret/keycloak-db-credentials \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/keycloak-demo-clients \
  -n api-monetization-identity --timeout=5m
oc wait --for=condition=Ready externalsecret/subscriptions-db-credentials \
  -n api-monetization-data --timeout=5m

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
oc wait --for=jsonpath='{.image.dockerImageReference}' \
  imagestreamtags.image.openshift.io/inventory-api:demo \
  -n api-monetization-apps --timeout=15m
oc wait --for=jsonpath='{.image.dockerImageReference}' \
  imagestreamtags.image.openshift.io/monetization-control:demo \
  -n api-monetization-data --timeout=15m
oc rollout status deployment/inventory-api -n api-monetization-apps --timeout=10m
oc rollout status deployment/monetization-control -n api-monetization-data --timeout=10m

echo "waiting for gateway, routes, policies, and catalog resources"
oc wait --for=condition=Programmed gateways.gateway.networking.k8s.io/api-monetization \
  -n api-monetization-gateway --timeout=10m
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
