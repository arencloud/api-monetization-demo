#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

namespace=api-monetization-ai
model=ai-chat
local_port=${AI_MODEL_TEST_PORT:-18083}
forward_log=$(mktemp)
forward_pid=""

cleanup() {
  if [[ -n $forward_pid ]]; then
    kill "$forward_pid" >/dev/null 2>&1 || true
    wait "$forward_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$forward_log"
}
trap cleanup EXIT

echo "waiting for the CPU model to become ready"
if ! oc wait --for=condition=Ready=true "inferenceservice.serving.kserve.io/$model" \
  -n "$namespace" --timeout=20m; then
  oc get "inferenceservice.serving.kserve.io/$model" -n "$namespace" -o yaml >&2 || true
  oc get pods -n "$namespace" -o wide >&2 || true
  exit 1
fi

service_name=$(oc get service -n "$namespace" \
  -l "serving.kserve.io/inferenceservice=$model" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z $service_name ]]; then
  echo "error: KServe did not create a predictor Service for $namespace/$model" >&2
  exit 1
fi

oc port-forward -n "$namespace" "service/$service_name" \
  "$local_port:8080" >"$forward_log" 2>&1 &
forward_pid=$!
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$local_port/health" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$forward_pid" >/dev/null 2>&1; then
    cat "$forward_log" >&2
    echo "error: model port-forward stopped unexpectedly" >&2
    exit 1
  fi
  sleep 1
done

response=$(curl -fsS "http://127.0.0.1:$local_port/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "ai-chat",
    "temperature": 0,
    "max_tokens": 32,
    "messages": [
      {"role": "system", "content": "Reply briefly."},
      {"role": "user", "content": "What platform is serving this model?"}
    ]
  }')

content=$(jq -r '.choices[0].message.content // empty' <<<"$response")
if [[ -z $content ]]; then
  jq . <<<"$response" >&2
  echo "error: the CPU model returned no chat completion" >&2
  exit 1
fi

echo "CPU-only OpenShift AI inference succeeded"
jq '{model, usage, answer: .choices[0].message.content}' <<<"$response"

