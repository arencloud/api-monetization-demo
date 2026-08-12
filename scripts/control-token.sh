#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

identity_namespace=api-monetization-identity
keycloak_route=api-monetization-keycloak
client_id=${CONTROL_TOKEN_CLIENT_ID:-monetization-automation}
credential_secret=${CONTROL_TOKEN_SECRET_NAME:-monetization-portal-credentials}
credential_key=${CONTROL_TOKEN_SECRET_KEY:-automation-client-secret}
route_ca_file=$(mktemp)

cleanup() {
  rm -f -- "$route_ca_file"
}
trap cleanup EXIT

oc wait --for=condition=Ready "externalsecret/$credential_secret" \
  -n "$identity_namespace" --timeout=5m >/dev/null
oc wait "route/$keycloak_route" -n "$identity_namespace" \
  --for=jsonpath='{.status.ingress[0].conditions[0].status}'=True \
  --timeout=5m >/dev/null

keycloak_hostname=$(oc get route "$keycloak_route" -n "$identity_namespace" \
  -o jsonpath='{.status.ingress[0].host}')
router_hostname=$(oc get route "$keycloak_route" -n "$identity_namespace" \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
if [[ -z $keycloak_hostname || -z $router_hostname ]]; then
  echo "error: Keycloak Route has no admitted host or router hostname" >&2
  exit 1
fi

ingress_certificate=$(oc get ingresscontroller.operator.openshift.io default \
  -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
if [[ -z $ingress_certificate ]]; then
  ingress_certificate=router-certs-default
fi
oc get secret "$ingress_certificate" -n openshift-ingress \
  -o go-template='{{index .data "tls.crt"}}' | base64 -d >"$route_ca_file"

client_secret=$(oc get secret "$credential_secret" \
  -n "$identity_namespace" \
  -o "go-template={{index .data \"$credential_key\"}}" | base64 -d)

token_response=$(curl --silent --show-error --fail \
  --cacert "$route_ca_file" \
  --connect-to "$keycloak_hostname:443:$router_hostname:443" \
  --user "$client_id:$client_secret" \
  --data 'grant_type=client_credentials' \
  "https://$keycloak_hostname/realms/api-monetization/protocol/openid-connect/token") || {
    echo "error: failed to obtain a monetization control-plane token through the Keycloak Route" >&2
    exit 1
  }

jq -er '.access_token' <<<"$token_response"
