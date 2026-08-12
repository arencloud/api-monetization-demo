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

[[ -n $hostname && -n $password ]] || {
  echo "error: Grafana Route or generated administrator credential is not ready" >&2
  exit 1
}

echo "Grafana: https://$hostname/d/api-monetization"
echo "Username: admin"
echo "Password: $password"
