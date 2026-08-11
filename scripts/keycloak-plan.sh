#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

operation=${1:-get}
desired_plan=${2:-}
case "$operation" in
  get)
    ;;
  set)
    case "$desired_plan" in
      free | developer | business)
        ;;
      *)
        echo "error: plan must be free, developer, or business" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "usage: $0 get | set <free|developer|business>" >&2
    exit 1
    ;;
esac

identity_namespace=api-monetization-identity
keycloak_service=api-monetization-service
keycloak_host=${keycloak_service}.${identity_namespace}.svc.cluster.local
keycloak_admin_port=${KEYCLOAK_ADMIN_LOCAL_PORT:-18082}
realm=api-monetization
client_id=demo-free-client
port_forward_pid=""

cleanup() {
  if [[ -n $port_forward_pid ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

oc port-forward -n "$identity_namespace" "service/$keycloak_service" \
  "$keycloak_admin_port:8080" >/tmp/api-monetization-keycloak-admin-port-forward.log 2>&1 &
port_forward_pid=$!

admin_username=$(oc get secret api-monetization-initial-admin \
  -n "$identity_namespace" -o go-template='{{index .data "username"}}' | base64 -d)
admin_password=$(oc get secret api-monetization-initial-admin \
  -n "$identity_namespace" -o go-template='{{index .data "password"}}' | base64 -d)
admin_form=$(jq -nr --arg username "$admin_username" --arg password "$admin_password" \
  '"username=\($username|@uri)&password=\($password|@uri)&grant_type=password&client_id=admin-cli"')

admin_token=""
for _ in $(seq 1 30); do
  if admin_response=$(printf '%s' "$admin_form" | curl --silent --fail \
      --connect-to "$keycloak_host:8080:127.0.0.1:$keycloak_admin_port" \
      --header 'content-type: application/x-www-form-urlencoded' \
      --data-binary @- \
      "http://$keycloak_host:8080/realms/master/protocol/openid-connect/token" \
      2>/dev/null); then
    admin_token=$(jq -er '.access_token' <<<"$admin_response")
    break
  fi
  sleep 1
done
if [[ -z $admin_token ]]; then
  echo "error: failed to obtain a Keycloak admin token" >&2
  exit 1
fi

admin_get() {
  curl --silent --show-error --fail-with-body \
    --connect-to "$keycloak_host:8080:127.0.0.1:$keycloak_admin_port" \
    --header "Authorization: Bearer $admin_token" \
    "http://$keycloak_host:8080/admin/realms/$realm/$1"
}

client=$(admin_get "clients?clientId=$client_id" \
  | jq -e 'if length == 1 then .[0] else error("expected exactly one Keycloak client") end')
client_uuid=$(jq -er '.id' <<<"$client")

read_plan_mapper() {
  admin_get "clients/$client_uuid/protocol-mappers/models" \
    | jq -e 'map(select(.name == "plan" and .protocolMapper == "oidc-hardcoded-claim-mapper"))
      | if length == 1 then .[0] else error("expected exactly one plan mapper") end'
}

mapper=$(read_plan_mapper)
current_plan=$(jq -er '.config["claim.value"]' <<<"$mapper")
if [[ $operation == "get" ]]; then
  printf '%s\n' "$current_plan"
  exit 0
fi

if [[ $current_plan != "$desired_plan" ]]; then
  mapper_id=$(jq -er '.id' <<<"$mapper")
  updated_mapper=$(jq --arg plan "$desired_plan" '.config["claim.value"] = $plan' <<<"$mapper")
  curl --silent --show-error --fail-with-body \
    --request PUT \
    --connect-to "$keycloak_host:8080:127.0.0.1:$keycloak_admin_port" \
    --header "Authorization: Bearer $admin_token" \
    --header 'content-type: application/json' \
    --data-binary @- \
    "http://$keycloak_host:8080/admin/realms/$realm/clients/$client_uuid/protocol-mappers/models/$mapper_id" \
    <<<"$updated_mapper"
  change_message="changed from $current_plan to $desired_plan"
else
  change_message="already set to $desired_plan"
fi

confirmed_plan=$(read_plan_mapper | jq -er '.config["claim.value"]')
if [[ $confirmed_plan != "$desired_plan" ]]; then
  echo "error: Keycloak plan mapper did not converge to $desired_plan" >&2
  exit 1
fi
echo "Keycloak client $client_id plan $change_message" >&2
printf '%s\n' "$confirmed_plan"
