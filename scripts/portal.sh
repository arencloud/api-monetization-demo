#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

oc wait --for=condition=Ready externalsecret/monetization-portal-credentials \
  -n api-monetization-identity --timeout=5m >/dev/null
oc wait --for=condition=Ready externalsecret/monetization-developer-credentials \
  -n api-monetization-identity --timeout=5m >/dev/null
oc wait route/monetization-control -n api-monetization-data \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True \
  --timeout=5m >/dev/null

portal_host=$(oc get route monetization-control -n api-monetization-data \
  -o jsonpath='{.status.ingress[0].host}')
admin_password=$(oc get secret monetization-portal-credentials \
  -n api-monetization-identity \
  -o go-template='{{index .data "portal-admin-password"}}' | base64 -d)
developer_password=$(oc get secret monetization-developer-credentials \
  -n api-monetization-identity \
  -o go-template='{{index .data "portal-developer-password"}}' | base64 -d)

printf 'Portal:             https://%s\n' "$portal_host"
printf 'Developer username: demo-developer\n'
printf 'Developer password: %s\n' "$developer_password"
printf 'Admin username:     demo-admin\n'
printf 'Admin password:     %s\n' "$admin_password"
