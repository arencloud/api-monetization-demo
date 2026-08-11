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
client_id=${CONTROL_TOKEN_CLIENT_ID:-monetization-automation}
credential_secret=${CONTROL_TOKEN_SECRET_NAME:-monetization-portal-credentials}
credential_key=${CONTROL_TOKEN_SECRET_KEY:-automation-client-secret}
port_forward_pid=""

cleanup() {
  if [[ -n $port_forward_pid ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

oc wait --for=condition=Ready "externalsecret/$credential_secret" \
  -n "$identity_namespace" --timeout=5m >/dev/null
oc port-forward -n "$identity_namespace" "service/$keycloak_service" \
  "$keycloak_port:8080" >/tmp/api-monetization-control-token-port-forward.log 2>&1 &
port_forward_pid=$!

client_secret=$(oc get secret "$credential_secret" \
  -n "$identity_namespace" \
  -o "go-template={{index .data \"$credential_key\"}}" | base64 -d)

for _ in $(seq 1 30); do
  if ! kill -0 "$port_forward_pid" 2>/dev/null; then
    echo "error: Keycloak port-forward stopped; local port $keycloak_port may already be in use" >&2
    sed -n '1,10p' /tmp/api-monetization-control-token-port-forward.log >&2
    exit 1
  fi
  if token_response=$(curl --silent --show-error --fail \
      --connect-to "$keycloak_host:8080:127.0.0.1:$keycloak_port" \
      --user "$client_id:$client_secret" \
      --data 'grant_type=client_credentials' \
      "http://$keycloak_host:8080/realms/api-monetization/protocol/openid-connect/token" \
      2>/dev/null); then
    jq -er '.access_token' <<<"$token_response"
    exit 0
  fi
  sleep 1
done

echo "error: failed to obtain a monetization control-plane token" >&2
echo "check /tmp/api-monetization-control-token-port-forward.log and the monetization-automation Keycloak client" >&2
exit 1
