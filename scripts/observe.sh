#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in oc curl jq base64; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: $command_name is required" >&2
    exit 1
  }
done

work_dir=$(mktemp -d)
trap 'rm -r -- "$work_dir"' EXIT

thanos_hostname=$(oc get route thanos-querier -n openshift-monitoring \
  -o jsonpath='{.spec.host}')
[[ -n $thanos_hostname ]] || {
  echo "error: OpenShift Thanos Querier Route is not admitted" >&2
  exit 1
}

ingress_certificate=$(oc get ingresscontroller.operator.openshift.io default \
  -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
[[ -n $ingress_certificate ]] || ingress_certificate=router-certs-default
oc get secret "$ingress_certificate" -n openshift-ingress \
  -o go-template='{{index .data "tls.crt"}}' | base64 -d >"$work_dir/route-ca.crt"
access_token=$(oc whoami -t)

query() {
  local expression=$1
  curl --silent --show-error --fail \
    --cacert "$work_dir/route-ca.crt" \
    --header "Authorization: Bearer $access_token" \
    --get --data-urlencode "query=$expression" \
    "https://$thanos_hostname/api/v1/query"
}

echo "commercial usage and revenue (current UTC month)"
query 'monetization_billable_units' | jq -r '
  if (.data.result | length) == 0 then "  no commercial metrics found"
  else .data.result[] |
    "  \(.metric.customer) / \(.metric.product) / \(.metric.plan): \(.value[1]) accepted billable units"
  end'
query 'monetization_overage_units' | jq -r '
  if (.data.result | length) == 0 then "  overage metric is not deployed yet"
  else .data.result[] |
    "  \(.metric.customer) / \(.metric.product) / \(.metric.plan): \(.value[1]) accepted overage units"
  end'
query 'monetization_projected_revenue_euros' | jq -r '
  if (.data.result | length) == 0 then "  no projected revenue found"
  else .data.result[] |
    "  \(.metric.customer) / \(.metric.product) / \(.metric.plan): €\(.value[1]) projected revenue"
  end'
query 'monetization_ai_prompt_tokens' | jq -r '
  if (.data.result | length) == 0 then "  no AI prompt tokens found"
  else .data.result[] |
    "  \(.metric.customer) / AI Chat / \(.metric.plan): \(.value[1]) prompt tokens"
  end'
query 'monetization_ai_completion_tokens' | jq -r '
  if (.data.result | length) == 0 then "  no AI completion tokens found"
  else .data.result[] |
    "  \(.metric.customer) / AI Chat / \(.metric.plan): \(.value[1]) completion tokens"
  end'

echo
echo "Connectivity Link decisions by credential (last hour)"
for decision in authorized limited; do
  metric="${decision}_calls"
  query "sum by (limitador_namespace) (increase(${metric}{limitador_namespace=~\"api-monetization-apps/(inventory|payments|ai-chat)-(api-key|jwt)\"}[1h]))" \
    | jq -r --arg decision "$decision" '
      if (.data.result | length) == 0 then "  no \($decision) calls found"
      else .data.result[] |
        (.metric.limitador_namespace | sub(".*/"; "")) as $policy |
        "  \($policy): \(.value[1] | tonumber | round) \($decision)"
      end'
done

echo
echo "gateway responses by HTTP status (last hour)"
query 'sum by (destination_service_name, response_code) (increase(istio_requests_total{reporter="source",source_workload_namespace="api-monetization-gateway",source_workload="api-monetization-istio",destination_service_name=~"(inventory|payments|ai-chat)-api",instance=~".*:15090"}[1h]))' \
  | jq -r '
    if (.data.result | length) == 0 then "  no gateway traffic found"
    else .data.result | sort_by(.metric.response_code)[] |
      "  \(.metric.destination_service_name) HTTP \(.metric.response_code): \(.value[1] | tonumber | round)"
    end'

echo
echo "Interpretation: HTTP 429 and limited_calls are observable policy denials, not billable usage."
echo "Accepted billable usage and revenue come from PostgreSQL-backed monetization metrics."
echo
echo "Grafana dashboard ConfigMap: api-monetization-observability/api-monetization-grafana-dashboard"
echo "OpenShift metrics UI: https://console-openshift-console.${thanos_hostname#thanos-querier-openshift-monitoring.}/monitoring/query-browser"
