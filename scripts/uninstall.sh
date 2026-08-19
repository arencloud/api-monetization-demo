#!/usr/bin/env bash

set -Eeuo pipefail

if [[ ${CONFIRM_UNINSTALL:-} != "api-monetization" ]]; then
  echo "error: this permanently deletes the API Monetization demo and its data" >&2
  echo "rerun with CONFIRM_UNINSTALL=api-monetization" >&2
  exit 1
fi

for command_name in oc jq timeout; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
done

delete_timeout_seconds=${UNINSTALL_DELETE_TIMEOUT_SECONDS:-120}
finalizer_timeout_seconds=${UNINSTALL_FINALIZER_TIMEOUT_SECONDS:-30}
namespace_timeout_seconds=${UNINSTALL_NAMESPACE_TIMEOUT_SECONDS:-180}

for timeout_value in \
  "$delete_timeout_seconds" \
  "$finalizer_timeout_seconds" \
  "$namespace_timeout_seconds"; do
  if [[ ! $timeout_value =~ ^[1-9][0-9]*$ ]]; then
    echo "error: uninstall timeouts must be positive integer seconds" >&2
    exit 1
  fi
done

cleanup_failed=false

warn() {
  echo "warning: $*" >&2
}

resource_get() {
  local resource=$1
  local name=$2
  local namespace=${3:-}
  shift 3
  local args=(get "$resource" "$name")
  [[ -n $namespace ]] && args+=(-n "$namespace")
  args+=("$@")
  oc "${args[@]}"
}

wait_for_absence() {
  local resource=$1
  local name=$2
  local namespace=$3
  local timeout_seconds=$4
  local deadline=$((SECONDS + timeout_seconds))

  while resource_get "$resource" "$name" "$namespace" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 2
  done
}

delete_with_finalizer_recovery() {
  local resource=$1
  local name=$2
  local namespace=${3:-}
  local description=${4:-$resource/$name}
  local args=(delete "$resource" "$name" --ignore-not-found --wait=false)
  [[ -n $namespace ]] && args+=(-n "$namespace")

  if ! resource_get "$resource" "$name" "$namespace" >/dev/null 2>&1; then
    return 0
  fi

  echo "deleting $description"
  if ! timeout --signal=TERM --kill-after=5s \
    "$((delete_timeout_seconds + 10))s" oc "${args[@]}"; then
    warn "delete request for $description did not complete normally"
  fi
  if wait_for_absence "$resource" "$name" "$namespace" \
    "$delete_timeout_seconds"; then
    return 0
  fi

  local object_json
  object_json=$(resource_get "$resource" "$name" "$namespace" -o json 2>/dev/null || true)
  if [[ -z $object_json ]]; then
    return 0
  fi
  if [[ -z $(jq -r '.metadata.deletionTimestamp // empty' <<<"$object_json") ]]; then
    warn "$description still exists without a deletion timestamp; refusing to clear finalizers"
    cleanup_failed=true
    return 1
  fi

  local finalizers
  finalizers=$(jq -r '(.metadata.finalizers // []) | join(", ")' <<<"$object_json")
  warn "$description is stuck terminating${finalizers:+ on finalizers: $finalizers}"
  echo "clearing orphaned finalizers from $description"
  local patch_args=(patch "$resource" "$name" --type=merge \
    -p '{"metadata":{"finalizers":[]}}')
  [[ -n $namespace ]] && patch_args+=(-n "$namespace")
  if ! timeout --signal=TERM --kill-after=5s \
    "$((finalizer_timeout_seconds + 10))s" oc "${patch_args[@]}"; then
    warn "could not clear finalizers from $description"
    cleanup_failed=true
    return 1
  fi
  if ! wait_for_absence "$resource" "$name" "$namespace" \
    "$finalizer_timeout_seconds"; then
    warn "$description remains after finalizer recovery"
    cleanup_failed=true
    return 1
  fi
}

delete_package() {
  local package=$1
  echo "deleting $package"
  if ! timeout --signal=TERM --kill-after=5s \
    "$((delete_timeout_seconds + 10))s" \
    oc delete -k "$package" --ignore-not-found --wait=true \
      --timeout="${delete_timeout_seconds}s"; then
    warn "$package did not finish deleting within ${delete_timeout_seconds}s; orphan cleanup will continue"
  fi
}

list_operator_csvs() {
  local namespace=$1
  local subscription=$2
  local package=${3:-$subscription}

  oc get clusterserviceversions.operators.coreos.com -n "$namespace" \
    -o json 2>/dev/null | jq -r --arg subscription "$subscription" \
    --arg package "$package" --arg namespace "$namespace" '
      .items[]?
      | select(
          ((.metadata.labels // {})
            | has("operators.coreos.com/" + $subscription + "." + $namespace))
          or
          ((.metadata.labels // {})
            | has("operators.coreos.com/" + $package + "." + $namespace))
        )
      | .metadata.name' || true
}

delete_labeled_resources() {
  local resource=$1
  local selector=$2
  local description=$3
  local name

  while IFS= read -r name; do
    [[ -z $name ]] && continue
    delete_with_finalizer_recovery "$resource" "$name" "" \
      "$description $name" || true
  done < <(
    oc get "$resource" -l "$selector" -o json 2>/dev/null \
      | jq -r '.items[]?.metadata.name' || true
  )
}

remove_operator() {
  local namespace=$1
  local subscription=$2
  local package=${3:-$subscription}
  local csvs=""

  if oc get subscription "$subscription" -n "$namespace" >/dev/null 2>&1; then
    csvs=$(oc get subscription "$subscription" -n "$namespace" \
      -o jsonpath='{.status.installedCSV}{"\n"}{.status.currentCSV}{"\n"}' \
      2>/dev/null || true)
  fi

  csvs+=$'\n'
  csvs+=$(list_operator_csvs "$namespace" "$subscription" "$package")

  delete_with_finalizer_recovery subscriptions.operators.coreos.com \
    "$subscription" "$namespace" "Subscription $namespace/$subscription" || true

  while IFS= read -r csv; do
    [[ -z $csv ]] && continue
    delete_with_finalizer_recovery clusterserviceversions.operators.coreos.com \
      "$csv" "$namespace" "CSV $namespace/$csv" || true
  done < <(awk 'NF && !seen[$0]++' <<<"$csvs")
}

sweep_terminating_namespace() {
  local namespace=$1
  local resource
  local object

  warn "sweeping remaining resources from terminating namespace $namespace"
  while IFS= read -r resource; do
    case "$resource" in
      events|events.events.k8s.io)
        continue
        ;;
    esac
    timeout --signal=TERM --kill-after=2s 12s \
      oc delete "$resource" --all -n "$namespace" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    while IFS= read -r object; do
      [[ -z $object ]] && continue
      timeout --signal=TERM --kill-after=2s 12s \
        oc patch "$resource" "$object" -n "$namespace" --type=merge \
          -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done < <(
      timeout --signal=TERM --kill-after=2s 12s \
        oc get "$resource" -n "$namespace" -o json 2>/dev/null \
        | jq -r '.items[]?
          | select((.metadata.finalizers // []) | length > 0)
          | .metadata.name' || true
    )
  done < <(oc api-resources --verbs=list --namespaced -o name | sort -u)
}

delete_namespace_with_recovery() {
  local namespace=$1

  if ! oc get namespace "$namespace" >/dev/null 2>&1; then
    return 0
  fi

  echo "deleting namespace $namespace"
  timeout --signal=TERM --kill-after=5s \
    "$((delete_timeout_seconds + 10))s" \
    oc delete namespace "$namespace" --wait=false >/dev/null 2>&1 || true
  if wait_for_absence namespaces "$namespace" "" "$namespace_timeout_seconds"; then
    return 0
  fi

  local namespace_json
  namespace_json=$(oc get namespace "$namespace" -o json 2>/dev/null || true)
  if [[ -z $namespace_json ]]; then
    return 0
  fi
  if [[ -z $(jq -r '.metadata.deletionTimestamp // empty' <<<"$namespace_json") ]]; then
    warn "namespace $namespace is not terminating; refusing forced cleanup"
    cleanup_failed=true
    return 1
  fi

  sweep_terminating_namespace "$namespace"
  if wait_for_absence namespaces "$namespace" "" "$finalizer_timeout_seconds"; then
    return 0
  fi

  warn "namespace $namespace is still stuck; finalizing the confirmed demo namespace"
  if ! oc get namespace "$namespace" -o json \
    | jq '.spec.finalizers = [] | .metadata.finalizers = []' \
    | timeout --signal=TERM --kill-after=5s \
        "$((finalizer_timeout_seconds + 10))s" \
        oc replace --raw "/api/v1/namespaces/$namespace/finalize" -f - \
          >/dev/null; then
    warn "forced finalization failed for namespace $namespace"
    cleanup_failed=true
    return 1
  fi
  if ! wait_for_absence namespaces "$namespace" "" \
    "$finalizer_timeout_seconds"; then
    warn "namespace $namespace remains after forced finalization"
    cleanup_failed=true
    return 1
  fi
}

echo "removing API Monetization from $(oc whoami --show-server)"

echo "stopping GitOps reconciliation"
if oc get application api-monetization-root -n openshift-gitops >/dev/null 2>&1; then
  timeout --signal=TERM --kill-after=5s \
    "$((finalizer_timeout_seconds + 10))s" \
    oc patch application api-monetization-root -n openshift-gitops \
      --type=merge -p '{"metadata":{"finalizers":[]}}' \
      >/dev/null || warn "could not detach the root Argo CD Application finalizer"
fi
delete_with_finalizer_recovery applications.argoproj.io api-monetization-root \
  openshift-gitops "root Argo CD Application" || true

mapfile -t child_applications < <(
  oc get applications.argoproj.io -n openshift-gitops \
    -l app.kubernetes.io/part-of=api-monetization -o name 2>/dev/null \
    | sed 's#^[^/]*/##' || true
)
if ((${#child_applications[@]} > 0)); then
  timeout --signal=TERM --kill-after=5s \
    "$((delete_timeout_seconds + 10))s" \
    oc delete applications.argoproj.io -n openshift-gitops \
      -l app.kubernetes.io/part-of=api-monetization \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
fi
for application in "${child_applications[@]}"; do
  delete_with_finalizer_recovery applications.argoproj.io "$application" \
    openshift-gitops "Argo CD Application $application" || true
done
for project in api-monetization-api-owners api-monetization; do
  delete_with_finalizer_recovery appprojects.argoproj.io "$project" \
    openshift-gitops "Argo CD AppProject $project" || true
done
delete_with_finalizer_recovery configmaps api-monetization-gitops-source \
  openshift-gitops "GitOps source ConfigMap" || true

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

delete_package applications/control
delete_package applications/ai-chat
delete_package applications/inventory
delete_package applications/payments
delete_package platform/developer-hub
delete_package platform/devspaces
delete_package platform/ai-model
delete_package platform/gateway
delete_package platform/identity
delete_package platform/database
delete_package platform/secrets/demo
delete_package platform/observability
delete_package platform/connectivity-link
delete_package platform/openshift-ai
delete_package platform/external-secrets
delete_package platform/service-mesh

echo "removing operator-managed cluster operands while their controllers are available"
delete_with_finalizer_recovery datascienceclusters.datasciencecluster.opendatahub.io \
  default-dsc "" "OpenShift AI DataScienceCluster/default-dsc" || true
delete_with_finalizer_recovery dscinitializations.dscinitialization.opendatahub.io \
  default-dsci "" "OpenShift AI DSCInitialization/default-dsci" || true
delete_with_finalizer_recovery certmanagers.operator.openshift.io \
  cluster "" "cert-manager operand" || true

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
remove_operator redhat-ods-operator rhods-operator
remove_operator rhdh-operator rhdh
remove_operator openshift-operators devspaces

echo "removing known operator-generated orphan resources"
delete_with_finalizer_recovery mutatingwebhookconfigurations.admissionregistration.k8s.io \
  mutating.odh-model-controller.opendatahub.io "" \
  "OpenShift AI model-controller webhook" || true
delete_with_finalizer_recovery consoleplugins.console.openshift.io \
  kuadrant-console-plugin "" "Kuadrant ConsolePlugin" || true
delete_with_finalizer_recovery consoleplugins.console.openshift.io \
  gitops-plugin "" "OpenShift GitOps ConsolePlugin" || true

for resource in \
  mutatingwebhookconfigurations.admissionregistration.k8s.io \
  validatingwebhookconfigurations.admissionregistration.k8s.io \
  clusterroles.rbac.authorization.k8s.io \
  clusterrolebindings.rbac.authorization.k8s.io; do
  delete_labeled_resources "$resource" \
    app.kubernetes.io/instance=cert-manager "cert-manager orphan $resource/"
done

delete_package platform/namespaces
for binding in \
  api-monetization-openshift-gitops-application-controller \
  api-monetization-catalog-browser; do
  delete_with_finalizer_recovery clusterrolebindings.rbac.authorization.k8s.io \
    "$binding" "" "ClusterRoleBinding $binding" || true
done

demo_namespaces=(
  openshift-devspaces
  rhdh-operator
  api-monetization-developer-hub
  redhat-ods-operator
  redhat-ods-applications
  redhat-ods-monitoring
  api-monetization-ai
  cert-manager
  cert-manager-operator
  kuadrant-system
  api-monetization-mesh-system
  api-monetization-istio-cni
  external-secrets-operator
  external-secrets
  api-monetization-identity
  api-monetization-data
  api-monetization-gateway
  api-monetization-apps
  openshift-opentelemetry-operator
  openshift-tempo-operator
  api-monetization-observability
)
for namespace in "${demo_namespaces[@]}"; do
  delete_namespace_with_recovery "$namespace" || true
done

is_demo_namespace() {
  local candidate=$1
  local demo_namespace

  for demo_namespace in \
    "${demo_namespaces[@]}" openshift-gitops openshift-gitops-operator; do
    if [[ $candidate == "$demo_namespace" ]]; then
      return 0
    fi
  done
  return 1
}

echo "uninstalling OpenShift GitOps last"
delete_with_finalizer_recovery gitopsservices.pipelines.openshift.io \
  cluster "" "OpenShift GitOps service" || true
remove_operator openshift-gitops-operator openshift-gitops-operator
delete_namespace_with_recovery openshift-gitops || true
delete_namespace_with_recovery openshift-gitops-operator || true

echo "removing persistent volumes formerly claimed by demo namespaces"
while IFS=$'\t' read -r volume claim_namespace; do
  [[ -z $volume || -z $claim_namespace ]] && continue
  if is_demo_namespace "$claim_namespace"; then
    delete_with_finalizer_recovery persistentvolumes "$volume" "" \
      "PersistentVolume $volume from $claim_namespace" || true
  fi
done < <(
  oc get persistentvolumes -o json 2>/dev/null \
    | jq -r '.items[]?
      | select(.spec.claimRef.namespace? != null)
      | [.metadata.name, .spec.claimRef.namespace]
      | @tsv' || true
)

remaining=()
for namespace in "${demo_namespaces[@]}" openshift-gitops openshift-gitops-operator; do
  if oc get namespace "$namespace" >/dev/null 2>&1; then
    remaining+=("namespace/$namespace")
  fi
done
for resource_ref in \
  appprojects.argoproj.io/api-monetization \
  appprojects.argoproj.io/api-monetization-api-owners \
  dscinitializations.dscinitialization.opendatahub.io/default-dsci \
  datascienceclusters.datasciencecluster.opendatahub.io/default-dsc \
  mutatingwebhookconfigurations.admissionregistration.k8s.io/mutating.odh-model-controller.opendatahub.io \
  consoleplugins.console.openshift.io/kuadrant-console-plugin \
  consoleplugins.console.openshift.io/gitops-plugin; do
  resource=${resource_ref%%/*}
  name=${resource_ref#*/}
  if oc get "$resource" "$name" >/dev/null 2>&1; then
    remaining+=("$resource_ref")
  fi
done
while IFS=$'\t' read -r volume claim_namespace; do
  [[ -z $volume || -z $claim_namespace ]] && continue
  if is_demo_namespace "$claim_namespace"; then
    remaining+=("persistentvolume/$volume")
  fi
done < <(
  oc get persistentvolumes -o json 2>/dev/null \
    | jq -r '.items[]?
      | select(.spec.claimRef.namespace? != null)
      | [.metadata.name, .spec.claimRef.namespace]
      | @tsv' || true
)
while IFS='|' read -r namespace subscription package; do
  if oc get subscriptions.operators.coreos.com "$subscription" \
    -n "$namespace" >/dev/null 2>&1; then
    remaining+=("subscription/$namespace/$subscription")
  fi
  while IFS= read -r csv; do
    [[ -z $csv ]] && continue
    remaining+=("csv/$namespace/$csv")
  done < <(list_operator_csvs "$namespace" "$subscription" "$package")
done <<'EOF'
api-monetization-identity|rhbk-operator|rhbk-operator
cert-manager-operator|openshift-cert-manager-operator|openshift-cert-manager-operator
external-secrets-operator|openshift-external-secrets-operator|openshift-external-secrets-operator
kuadrant-system|rhcl-operator|rhcl-operator
kuadrant-system|authorino-operator-stable-redhat-operators-openshift-marketplace|authorino-operator-stable-redhat-operators-openshift-marketplace
kuadrant-system|dns-operator-stable-redhat-operators-openshift-marketplace|dns-operator-stable-redhat-operators-openshift-marketplace
kuadrant-system|limitador-operator-stable-redhat-operators-openshift-marketplace|limitador-operator-stable-redhat-operators-openshift-marketplace
openshift-opentelemetry-operator|opentelemetry-product|opentelemetry-product
openshift-operators|cloudnative-pg|cloudnative-pg
openshift-operators|servicemeshoperator3|servicemeshoperator3
openshift-tempo-operator|tempo-product|tempo-product
openshift-operators|grafana-operator|grafana-operator
redhat-ods-operator|rhods-operator|rhods-operator
rhdh-operator|rhdh|rhdh
openshift-operators|devspaces|devspaces
openshift-gitops-operator|openshift-gitops-operator|openshift-gitops-operator
EOF

if [[ $cleanup_failed == true || ${#remaining[@]} -gt 0 ]]; then
  echo "error: API Monetization removal completed with unresolved resources" >&2
  printf '  %s\n' "${remaining[@]}" >&2
  echo "inspect the reported resources before reinstalling" >&2
  exit 1
fi

echo "API Monetization removal complete"
echo "Operator CRDs and the integrated image registry are retained intentionally"
