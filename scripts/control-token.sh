#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

identity_namespace=api-monetization-identity
keycloak_service=api-monetization-service
keycloak_host=${keycloak_service}.${identity_namespace}.svc.cluster.local
keycloak_port=${CONTROL_TOKEN_LOCAL_PORT:-18083}
port_forward_pid=""

cleanup() {
  if [[ -n $port_forward_pid ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

oc wait --for=condition=Ready externalsecret/monetization-portal-credentials \
  -n "$identity_namespace" --timeout=5m >/dev/null
oc port-forward -n "$identity_namespace" "service/$keycloak_service" \
  "$keycloak_port:8080" >/tmp/api-monetization-control-token-port-forward.log 2>&1 &
port_forward_pid=$!

client_secret=$(oc get secret monetization-portal-credentials \
  -n "$identity_namespace" \
  -o go-template='{{index .data "automation-client-secret"}}' | base64 -d)

for _ in $(seq 1 30); do
  if token_response=$(curl --silent --show-error --fail \
      --connect-to "$keycloak_host:8080:127.0.0.1:$keycloak_port" \
      --user "monetization-automation:$client_secret" \
      --data 'grant_type=client_credentials' \
      "http://$keycloak_host:8080/realms/api-monetization/protocol/openid-connect/token" \
      2>/dev/null); then
    jq -er '.access_token' <<<"$token_response"
    exit 0
  fi
  sleep 1
done

echo "error: failed to obtain a monetization control-plane token" >&2
exit 1
