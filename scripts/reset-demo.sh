#!/usr/bin/env bash

set -Eeuo pipefail

control_port=${CONTROL_LOCAL_PORT:-18080}

cleanup() {
  kill "$port_forward_pid" 2>/dev/null || true
}
trap cleanup EXIT

oc port-forward -n api-monetization-data service/monetization-control \
  "$control_port:8080" >/tmp/api-monetization-control-port-forward.log 2>&1 &
port_forward_pid=$!

for _ in $(seq 1 30); do
  curl --silent --fail "http://127.0.0.1:$control_port/readyz" >/dev/null && break
  sleep 1
done

curl --silent --fail-with-body \
  --header 'content-type: application/json' \
  --data '{"plan":"free"}' \
  "http://127.0.0.1:$control_port/api/subscriptions/demo-company/plan"
echo
echo "demo subscription reset to Free; rate-limit counters expire with their configured windows"
