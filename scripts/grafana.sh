#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc base64; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: $command_name is required" >&2
    exit 1
  }
done

namespace=api-monetization-observability
instance=api-monetization-grafana

oc wait --for=condition=GrafanaReady \
  "grafanas.grafana.integreatly.org/$instance" \
  -n "$namespace" --timeout=10m >/dev/null
oc wait --for=condition=DatasourceSynchronized \
  grafanadatasources.grafana.integreatly.org/api-monetization-thanos \
  -n "$namespace" --timeout=5m >/dev/null
oc wait --for=condition=DashboardSynchronized \
  grafanadashboards.grafana.integreatly.org/api-monetization \
  -n "$namespace" --timeout=5m >/dev/null

hostname=$(oc get route "$instance-route" -n "$namespace" \
  -o jsonpath='{.status.ingress[0].host}')
password=$(oc get secret api-monetization-grafana-admin -n "$namespace" \
  -o go-template='{{index .data "GF_SECURITY_ADMIN_PASSWORD"}}' | base64 -d)
admin_password=$(oc get secret monetization-portal-credentials \
  -n api-monetization-identity \
  -o go-template='{{index .data "portal-admin-password"}}' | base64 -d)
developer_password=$(oc get secret monetization-developer-credentials \
  -n api-monetization-identity \
  -o go-template='{{index .data "portal-developer-password"}}' | base64 -d)

[[ -n $hostname && -n $password && -n $admin_password && -n $developer_password ]] || {
  echo "error: Grafana Route or generated SSO/break-glass credentials are not ready" >&2
  exit 1
}

echo "Grafana: https://$hostname/d/api-monetization"
echo "Keycloak administrator: demo-admin"
echo "Administrator password: $admin_password"
echo "Keycloak viewer: demo-developer"
echo "Viewer password: $developer_password"
echo "Break-glass login: https://$hostname/login?disableAutoLogin=true"
echo "Break-glass username: admin"
echo "Break-glass password: $password"
