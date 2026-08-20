#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

identity_namespace=api-monetization-identity
hub_namespace=api-monetization-developer-hub
work_dir=$(mktemp -d)
cookie_jar="$work_dir/cookies"
auth_html="$work_dir/auth.html"
registration_html="$work_dir/registration.html"
response_headers="$work_dir/response.headers"
response_body="$work_dir/response.body"
test_username="registration-check-$(date +%s)-$RANDOM"
test_email="$test_username@example.invalid"
test_password='Test-only-Strong-Password-97!'
test_user_id=""
keycloak_admin_token=""

cleanup() {
  if [[ -n $test_user_id && -n $keycloak_admin_token ]]; then
    curl --silent --output /dev/null --request DELETE \
      --cacert "$route_ca_file" \
      --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
      --header "Authorization: Bearer $keycloak_admin_token" \
      "https://$keycloak_hostname/admin/realms/api-monetization/users/$test_user_id" \
      || true
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

ingress_certificate=$(oc get ingresscontroller.operator.openshift.io default \
  -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
if [[ -z $ingress_certificate ]]; then
  ingress_certificate=router-certs-default
fi
route_ca_file="$work_dir/route-ca.crt"
oc get secret "$ingress_certificate" -n openshift-ingress \
  -o go-template='{{index .data "tls.crt"}}' | base64 -d >"$route_ca_file"

keycloak_hostname=$(oc get route api-monetization-keycloak \
  -n "$identity_namespace" -o jsonpath='{.status.ingress[0].host}')
keycloak_router_hostname=$(oc get route api-monetization-keycloak \
  -n "$identity_namespace" -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
rhdh_hostname=$(oc get route backstage-api-monetization \
  -n "$hub_namespace" -o jsonpath='{.status.ingress[0].host}')

keycloak_admin=$(oc get secret api-monetization-initial-admin \
  -n "$identity_namespace" -o go-template='{{index .data "username"}}' | base64 -d)
keycloak_admin_password=$(oc get secret api-monetization-initial-admin \
  -n "$identity_namespace" -o go-template='{{index .data "password"}}' | base64 -d)
keycloak_admin_token=$(curl --silent --show-error --fail \
  --cacert "$route_ca_file" \
  --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
  --data-urlencode "username=$keycloak_admin" \
  --data-urlencode "password=$keycloak_admin_password" \
  --data client_id=admin-cli \
  --data grant_type=password \
  "https://$keycloak_hostname/realms/master/protocol/openid-connect/token" \
  | jq -er .access_token)

rhdh_logs=$(oc logs deployment/backstage-api-monetization -n "$hub_namespace" \
  --container=backstage-backend)
if ! grep -q 'KeycloakOrgEntityProvider:default:refresh.*"cadence":"PT10S"' \
  <<<"$rhdh_logs"; then
  echo "error: effective RHDH Keycloak synchronization cadence is not PT10S" >&2
  exit 1
fi

curl --silent --show-error --fail \
  --cacert "$route_ca_file" \
  --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
  --cookie-jar "$cookie_jar" \
  --get "https://$keycloak_hostname/realms/api-monetization/protocol/openid-connect/auth" \
  --data-urlencode client_id=rhdh \
  --data-urlencode "redirect_uri=https://$rhdh_hostname/api/auth/oidc/handler/frame" \
  --data-urlencode response_type=code \
  --data-urlencode 'scope=openid profile email' \
  --data-urlencode code_challenge=0123456789012345678901234567890123456789012 \
  --data-urlencode code_challenge_method=S256 >"$auth_html"

registration_url=$(grep 'Create developer account' "$auth_html" \
  | head -n 1 | sed -n 's/.*href="\([^"]*\)".*/\1/p' \
  | sed 's/&amp;/\&/g')
if [[ $registration_url == /* ]]; then
  registration_url="https://$keycloak_hostname$registration_url"
fi
if [[ $registration_url != https://* ]]; then
  echo "error: Keycloak registration link was not published" >&2
  exit 1
fi

curl --silent --show-error --fail \
  --cacert "$route_ca_file" \
  --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
  --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
  "$registration_url" >"$registration_html"
registration_action=$(grep 'id="kc-register-form"' "$registration_html" \
  | head -n 1 | sed -n 's/.*action="\([^"]*\)".*/\1/p' \
  | sed 's/&amp;/\&/g')
if [[ $registration_action == /* ]]; then
  registration_action="https://$keycloak_hostname$registration_action"
fi
if [[ $registration_action != https://* ]]; then
  echo "error: Keycloak registration form action was not published" >&2
  exit 1
fi

registration_status=$(curl --silent --show-error \
  --output "$response_body" --dump-header "$response_headers" \
  --write-out '%{http_code}' \
  --cacert "$route_ca_file" \
  --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
  --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
  --request POST "$registration_action" \
  --data-urlencode "username=$test_username" \
  --data-urlencode "email=$test_email" \
  --data-urlencode firstName=Registration \
  --data-urlencode lastName=Check \
  --data-urlencode "password=$test_password" \
  --data-urlencode "password-confirm=$test_password")
if [[ $registration_status != 302 && $registration_status != 303 ]]; then
  echo "error: Keycloak self-registration returned HTTP $registration_status" >&2
  exit 1
fi

registered_users=$(curl --silent --show-error --fail \
  --cacert "$route_ca_file" \
  --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
  --header "Authorization: Bearer $keycloak_admin_token" \
  --get "https://$keycloak_hostname/admin/realms/api-monetization/users" \
  --data-urlencode "username=$test_username" \
  --data-urlencode exact=true)
if ! jq -e 'length == 1 and .[0].emailVerified == true' \
  <<<"$registered_users" >/dev/null; then
  echo "error: successful demo registration was not marked email verified" >&2
  exit 1
fi
test_user_id=$(jq -er '.[0].id' <<<"$registered_users")
if [[ ! $test_user_id =~ ^[0-9a-f-]+$ ]]; then
  echo "error: Keycloak returned an invalid registration subject" >&2
  exit 1
fi

user_groups=$(curl --silent --show-error --fail \
  --cacert "$route_ca_file" \
  --connect-to "$keycloak_hostname:443:$keycloak_router_hostname:443" \
  --header "Authorization: Bearer $keycloak_admin_token" \
  "https://$keycloak_hostname/admin/realms/api-monetization/users/$test_user_id/groups")
if ! jq -e 'any(.[]; .name == "api-consumers")' <<<"$user_groups" >/dev/null; then
  echo "error: registered user did not inherit api-consumers" >&2
  exit 1
fi

echo "waiting for RHDH to synchronize the registered consumer"
catalog_count=0
for _ in $(seq 1 20); do
  catalog_count=$(oc exec -n "$hub_namespace" api-monetization-rhdh-postgres-1 -- \
    psql -U postgres -d rhdh -Atc \
    "SELECT count(*) FROM catalog.final_entities WHERE lower(final_entity::jsonb->>'kind')='user' AND final_entity::jsonb#>>'{metadata,annotations,keycloak.org/id}'='$test_user_id';" \
    2>/dev/null | tail -n 1)
  if [[ $catalog_count == 1 ]]; then
    break
  fi
  sleep 2
done
if [[ $catalog_count != 1 ]]; then
  echo "error: RHDH did not synchronize the registered user within 40 seconds" >&2
  exit 1
fi

echo "onboarding test passed: verified consumer registration synchronized to RHDH"
