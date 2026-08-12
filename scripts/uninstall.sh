#!/usr/bin/env bash

set -Eeuo pipefail

if [[ ${CONFIRM_UNINSTALL:-} != "api-monetization" ]]; then
  echo "error: this permanently deletes the API Monetization demo and its data" >&2
  echo "rerun with CONFIRM_UNINSTALL=api-monetization" >&2
  exit 1
fi

for command_name in oc jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

echo "removing API Monetization from $(oc whoami --show-server)"

echo "stopping GitOps reconciliation"
if oc get application api-monetization-root -n openshift-gitops >/dev/null 2>&1; then
  oc patch application api-monetization-root -n openshift-gitops \
    --type=merge -p '{"metadata":{"finalizers":[]}}'
  oc delete application api-monetization-root -n openshift-gitops \
    --ignore-not-found --wait=true --timeout=2m
fi
for attempt in $(seq 1 6); do
  oc delete applications.argoproj.io -n openshift-gitops \
    -l app.kubernetes.io/part-of=api-monetization \
    --ignore-not-found --wait=true --timeout=2m 2>/dev/null || true
  remaining_applications=$(oc get applications.argoproj.io -n openshift-gitops \
    -l app.kubernetes.io/part-of=api-monetization -o name 2>/dev/null || true)
  [[ -z $remaining_applications ]] && break
  sleep 2
done

echo "disabling API Monetization operator console plugins"
if oc get console.operator.openshift.io cluster >/dev/null 2>&1; then
  console_patch=$(oc get console.operator.openshift.io cluster -o json | jq -c '{
    spec: {
      plugins: [
        .spec.plugins[]?
        | select(. != "gitops-plugin" and . != "kuadrant-console-plugin")
      ]
    }
  }')
  oc patch console.operator.openshift.io cluster --type=merge -p "$console_patch"
  oc annotate console.operator.openshift.io cluster \
    argocd.argoproj.io/sync-options- >/dev/null 2>&1 || true
  oc label console.operator.openshift.io cluster \
    app.kubernetes.io/name- app.kubernetes.io/part-of- >/dev/null 2>&1 || true
fi

delete_package() {
  local package=$1
  echo "deleting $package"
  oc delete -k "$package" --ignore-not-found --wait=true --timeout=10m
}

delete_package applications/control
delete_package applications/inventory
delete_package platform/gateway
delete_package platform/identity
delete_package platform/database
delete_package platform/secrets/demo
delete_package platform/observability
delete_package platform/connectivity-link
delete_package platform/external-secrets
delete_package platform/service-mesh

echo "removing the cert-manager operand before its Operator"
if oc get certmanager.operator.openshift.io cluster >/dev/null 2>&1; then
  oc delete certmanager.operator.openshift.io cluster --wait=true --timeout=10m
fi

remove_operator() {
  local namespace=$1
  local subscription=$2
  local csvs

  if ! oc get subscription "$subscription" -n "$namespace" >/dev/null 2>&1; then
    return 0
  fi

  csvs=$(oc get subscription "$subscription" -n "$namespace" \
    -o jsonpath='{.status.installedCSV}{"\n"}{.status.currentCSV}{"\n"}' \
    | awk 'NF && !seen[$0]++')
  oc delete subscription "$subscription" -n "$namespace" \
    --ignore-not-found --wait=true --timeout=5m
  while IFS= read -r csv; do
    [[ -z $csv ]] && continue
    oc delete csv "$csv" -n "$namespace" \
      --ignore-not-found --wait=true --timeout=10m
  done <<<"$csvs"
}

echo "uninstalling application and platform Operators"
remove_operator api-monetization-identity rhbk-operator
remove_operator cert-manager-operator openshift-cert-manager-operator
remove_operator external-secrets-operator openshift-external-secrets-operator
remove_operator kuadrant-system rhcl-operator
remove_operator kuadrant-system authorino-operator-stable-redhat-operators-openshift-marketplace
remove_operator kuadrant-system dns-operator-stable-redhat-operators-openshift-marketplace
remove_operator kuadrant-system limitador-operator-stable-redhat-operators-openshift-marketplace
remove_operator openshift-opentelemetry-operator opentelemetry-product
remove_operator openshift-operators cloudnative-pg
remove_operator openshift-operators servicemeshoperator3
remove_operator openshift-tempo-operator tempo-product
remove_operator openshift-operators grafana-operator

oc delete mutatingwebhookconfiguration,validatingwebhookconfiguration \
  -l app.kubernetes.io/instance=cert-manager \
  --ignore-not-found --wait=true --timeout=2m
oc delete clusterrole,clusterrolebinding \
  -l app.kubernetes.io/instance=cert-manager \
  --ignore-not-found --wait=true --timeout=2m
oc delete namespace cert-manager --ignore-not-found --wait=true --timeout=10m

delete_package platform/namespaces
oc delete clusterrolebinding \
  api-monetization-openshift-gitops-application-controller \
  api-monetization-catalog-browser \
  --ignore-not-found --wait=true --timeout=2m

echo "uninstalling OpenShift GitOps last"
oc delete gitopsservice cluster --ignore-not-found --wait=true --timeout=10m 2>/dev/null || true
remove_operator openshift-gitops-operator openshift-gitops-operator
oc delete namespace openshift-gitops openshift-gitops-operator \
  --ignore-not-found --wait=true --timeout=10m

echo "API Monetization removal complete"
echo "Operator CRDs are retained intentionally for safe OLM reinstallation"
