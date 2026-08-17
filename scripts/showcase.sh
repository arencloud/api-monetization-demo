#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: $command_name is required" >&2
    exit 1
  }
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
counter_wait_seconds=${SHOWCASE_COUNTER_WAIT_SECONDS:-65}
metrics_wait_seconds=${SHOWCASE_METRICS_WAIT_SECONDS:-30}
metered_requests=${SHOWCASE_METERED_REQUESTS:-5}
current_stage="initialization"
cleanup_required=false
completed_stages=()
completed_durations=()

[[ $counter_wait_seconds =~ ^[0-9]+$ && $counter_wait_seconds -ge 60 && \
  $counter_wait_seconds -le 180 ]] || {
  echo "error: SHOWCASE_COUNTER_WAIT_SECONDS must be between 60 and 180" >&2
  exit 1
}
[[ $metrics_wait_seconds =~ ^[0-9]+$ && $metrics_wait_seconds -le 120 ]] || {
  echo "error: SHOWCASE_METRICS_WAIT_SECONDS must be between 0 and 120" >&2
  exit 1
}
[[ $metered_requests =~ ^[1-9][0-9]*$ && $metered_requests -le 100 ]] || {
  echo "error: SHOWCASE_METERED_REQUESTS must be between 1 and 100" >&2
  exit 1
}

print_rule() {
  printf '%*s\n' 78 '' | tr ' ' '='
}

wait_with_progress() {
  local total=$1
  local reason=$2
  local remaining=$total

  if ((total == 0)); then
    return 0
  fi

  echo "$reason"
  while ((remaining > 0)); do
    local interval=5
    if ((remaining < interval)); then
      interval=$remaining
    fi
    sleep "$interval"
    remaining=$((remaining - interval))
    if ((remaining > 0 && (remaining % 10 == 0 || remaining < 10))); then
      echo "  $remaining seconds remaining"
    fi
  done
}

run_stage() {
  local label=$1
  shift
  local started=$SECONDS
  local status

  current_stage=$label
  echo
  print_rule
  echo "SHOWCASE: $label"
  print_rule
  if "$@"; then
    status=0
  else
    status=$?
  fi
  if ((status != 0)); then
    echo "error: showcase stage '$label' failed with exit code $status" >&2
    return "$status"
  fi

  completed_stages+=("$label")
  completed_durations+=("$((SECONDS - started))")
}

print_presentation_endpoints() {
  local api_hostname
  local jwt_hostname
  local keycloak_hostname
  local tempo_hostname

  api_hostname=$(oc get route api-monetization -n api-monetization-gateway \
    -o jsonpath='{.status.ingress[0].host}')
  jwt_hostname=$(oc get route api-monetization-jwt -n api-monetization-gateway \
    -o jsonpath='{.status.ingress[0].host}')
  keycloak_hostname=$(oc get route api-monetization-keycloak -n api-monetization-identity \
    -o jsonpath='{.status.ingress[0].host}')
  tempo_hostname=$(oc get route tempo-api-monetization-jaegerui \
    -n api-monetization-observability -o jsonpath='{.status.ingress[0].host}')

  [[ -n $api_hostname && -n $jwt_hostname && -n $keycloak_hostname && \
    -n $tempo_hostname ]] || {
    echo "error: one or more presentation Routes are not admitted" >&2
    return 1
  }

  echo "API-key endpoint: https://$api_hostname/inventory"
  echo "JWT endpoint:     https://$jwt_hostname/inventory"
  echo "Payment API key:  https://$api_hostname/payments"
  echo "Payment JWT:      https://$jwt_hostname/payments"
  echo "AI Chat API key:  https://$api_hostname/v1/chat/completions"
  echo "AI Chat JWT:      https://$jwt_hostname/v1/chat/completions"
  echo "Keycloak:         https://$keycloak_hostname"
  echo "Tempo traces:     https://$tempo_hostname"
  echo
  "$script_dir/portal.sh" || return
  echo
  "$script_dir/grafana.sh" || return
}

restore_after_failure() {
  echo
  echo "restoring Demo Company to the Free plan after an interrupted or failed showcase"
  if "$script_dir/reset-demo.sh"; then
    echo "Demo Company is Free; any existing counters expire automatically within one minute"
  else
    echo "warning: automatic plan restoration failed; run 'make reset-demo' manually" >&2
  fi
}

finish() {
  local status=$?
  trap - EXIT

  if [[ $cleanup_required == "true" ]]; then
    restore_after_failure
  fi

  echo
  print_rule
  if ((status == 0)); then
    echo "SHOWCASE RESULT: PASS"
  else
    echo "SHOWCASE RESULT: FAIL during '$current_stage' (exit code $status)"
  fi
  print_rule
  local index
  for index in "${!completed_stages[@]}"; do
    printf '  [PASS] %-48s %4ss\n' \
      "${completed_stages[$index]}" "${completed_durations[$index]}"
  done
  if ((status != 0)); then
    printf '  [FAIL] %s\n' "$current_stage"
  fi
  echo
  echo "Accepted usage and invoice history remain stored as auditable demo evidence."
  exit "$status"
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print_rule
echo "API MONETIZATION COMPLETE SHOWCASE"
echo "Connectivity Link enforcement, Keycloak identity, billing, and observability"
print_rule

run_stage "Platform readiness and end-to-end verification" \
  "$script_dir/verify.sh"

run_stage "Independent Inventory and Payment subscriptions" \
  "$script_dir/multi-product-test.sh"

run_stage "AI Chat Free token quota and live Developer upgrade" \
  "$script_dir/ai-demo.sh"

run_stage "Reset shared subscription to Free" \
  "$script_dir/reset-demo.sh"
cleanup_required=true

run_stage "Expire previous Free-plan counters" \
  wait_with_progress "$counter_wait_seconds" \
  "waiting $counter_wait_seconds seconds for the real one-minute rate-limit windows"

run_stage "API-key and JWT live plan upgrade" \
  "$script_dir/demo.sh"

run_stage "Pay-as-you-go usage and draft invoice" \
  env METERED_DEMO_REQUESTS="$metered_requests" "$script_dir/metered-demo.sh"

run_stage "Publish fresh Prometheus evidence" \
  wait_with_progress "$metrics_wait_seconds" \
  "waiting $metrics_wait_seconds seconds for user-workload monitoring to scrape the result"

run_stage "Business and enforcement evidence" \
  "$script_dir/observe.sh"

run_stage "Presentation URLs and SSO identities" \
  print_presentation_endpoints

run_stage "Restore shared subscription to Free" \
  "$script_dir/reset-demo.sh"

run_stage "Prepare the next deterministic run" \
  wait_with_progress "$counter_wait_seconds" \
  "waiting $counter_wait_seconds seconds for the restored Free-plan counters"

cleanup_required=false
current_stage="complete"
