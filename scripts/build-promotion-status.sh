#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

promotion_status() {
  local application_name=$1
  local namespace=$2
  local build_config=$3
  local deployment_name=$4
  local container_name=$5
  local revision short_revision immutable_tag build_record build_name build_phase build_digest
  local tag_digest deployment_image ready_pods total_pods result

  revision=$(oc get application "$application_name" -n openshift-gitops \
    -o jsonpath='{.status.sync.revision}')
  short_revision=${revision:0:12}
  immutable_tag="git-$short_revision"
  build_record=$(oc get builds -n "$namespace" \
    -l "openshift.io/build-config.name=$build_config" -o json | jq -r --arg revision "$revision" '
      [.items[] | select(.spec.revision.git.commit == $revision)]
      | sort_by(.metadata.creationTimestamp)
      | last
      | if . == null then ["none", "Missing", "none"] | @tsv else
          [.metadata.name, .status.phase, (.status.output.to.imageDigest // "")] | @tsv
        end')
  IFS=$'\t' read -r build_name build_phase build_digest <<<"$build_record"
  tag_digest=$(oc get "imagestreamtag/$build_config:$immutable_tag" -n "$namespace" \
    -o jsonpath='{.image.metadata.name}' 2>/dev/null || true)
  deployment_image=$(oc get deployment "$deployment_name" -n "$namespace" \
    -o json | jq -r --arg container "$container_name" \
      '.spec.template.spec.containers[] | select(.name == $container) | .image')
  read -r ready_pods total_pods < <(oc get pods -n "$namespace" \
    -l "app.kubernetes.io/name=$deployment_name" -o json | jq -r --arg container "$container_name" '
      [.items[] | .status.containerStatuses[]? | select(.name == $container)] as $statuses
      | [([$statuses[] | select(.ready == true)] | length), ($statuses | length)] | @tsv')

  result=Ready
  if [[ ! $revision =~ ^[0-9a-f]{40}$ || $build_phase != Complete || $build_digest != sha256:* \
    || $tag_digest != "$build_digest" || $deployment_image != *@"$build_digest" \
    || $ready_pods == 0 || $ready_pods != "$total_pods" ]]; then
    result=Mismatch
  fi

  printf '%-23s %-8s revision=%s build=%s/%s image=%s pods=%s/%s\n' \
    "$application_name" "$result" "$short_revision" "${build_name:-none}" "$build_phase" \
    "${build_digest:-none}" "$ready_pods" "$total_pods"

  [[ $result == Ready ]]
}

echo "GitOps build promotion provenance"
failed=0
promotion_status api-monetization-control api-monetization-data \
  monetization-control monetization-control monetization-control || failed=1
promotion_status api-monetization-inventory api-monetization-apps \
  inventory-api inventory-api inventory-api || failed=1
promotion_status api-monetization-payments api-monetization-apps \
  payments-api payments-api payments-api || failed=1
promotion_status api-monetization-ai-chat api-monetization-apps \
  ai-chat-api ai-chat-api ai-chat-api || failed=1

if ((failed)); then
  echo "error: one or more deployed images do not match their reconciled Git revisions" >&2
  exit 1
fi

echo "all running application images have verified immutable Git provenance"
