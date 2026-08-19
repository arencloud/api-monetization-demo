#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

oc rollout status deployment/backstage-api-monetization \
  -n api-monetization-developer-hub --timeout=15m
oc wait route/backstage-api-monetization -n api-monetization-developer-hub \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True --timeout=5m

hub_host=$(oc get route backstage-api-monetization \
  -n api-monetization-developer-hub -o jsonpath='{.status.ingress[0].host}')
admin_password=$(oc get secret monetization-portal-credentials \
  -n api-monetization-identity \
  -o go-template='{{index .data "portal-admin-password"}}' | base64 -d)
developer_password=$(oc get secret monetization-developer-credentials \
  -n api-monetization-identity \
  -o go-template='{{index .data "portal-developer-password"}}' | base64 -d)
devspaces_url=$(oc get checluster.org.eclipse.che devspaces \
  -n openshift-devspaces -o jsonpath='{.status.cheURL}')

printf 'Developer Hub:      https://%s\n' "$hub_host"
printf 'OpenShift Dev Spaces: %s\n' "$devspaces_url"
printf 'Developer username: demo-developer\n'
printf 'Developer password: %s\n' "$developer_password"
printf 'Admin username:     demo-admin\n'
printf 'Admin password:     %s\n' "$admin_password"
printf '\nConsumer pages: /monetized-apis, /billing\n'
printf 'Technical policy view (not in navigation): /kuadrant/api-products\n'
