#!/usr/bin/env bash

set -Eeuo pipefail

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc is required" >&2
  exit 1
fi

failures=0

pass() {
  echo "PASS: $*"
}

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

if user_name=$(oc whoami 2>/dev/null); then
  pass "connected to the cluster as $user_name"
else
  echo "error: no working OpenShift login" >&2
  exit 1
fi

server_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
if [[ $server_version =~ ^4\.([0-9]+)\. ]]; then
  server_minor=${BASH_REMATCH[1]}
  if ((server_minor >= 21 && server_minor <= 22)); then
    pass "OpenShift $server_version is in the supported 4.21-4.22 range"
  else
    fail "OpenShift $server_version is outside the supported 4.21-4.22 range"
  fi
else
  fail "could not determine the OpenShift server version"
fi

for permission in \
  'create namespaces' \
  'create clusterrolebindings.rbac.authorization.k8s.io --all-namespaces' \
  'create subscriptions.operators.coreos.com --all-namespaces' \
  'create operatorgroups.operators.coreos.com --all-namespaces'; do
  read -r verb resource scope <<<"$permission"
  if [[ ${scope:-} == "--all-namespaces" ]]; then
    allowed=$(oc auth can-i "$verb" "$resource" --all-namespaces 2>/dev/null || true)
  else
    allowed=$(oc auth can-i "$verb" "$resource" 2>/dev/null || true)
  fi
  if [[ $allowed == "yes" ]]; then
    pass "authorized to $permission"
  else
    fail "not authorized to $permission"
  fi
done

if [[ $(oc auth can-i bind clusterroles.rbac.authorization.k8s.io/cluster-admin \
  2>/dev/null || true) == "yes" ]]; then
  pass "authorized to bind the cluster-admin ClusterRole"
else
  fail "not authorized to bind the cluster-admin ClusterRole"
fi

if oc get catalogsource redhat-operators -n openshift-marketplace >/dev/null 2>&1; then
  pass "redhat-operators catalog source is available"
else
  fail "redhat-operators catalog source is unavailable"
fi

if oc get catalogsource certified-operators -n openshift-marketplace >/dev/null 2>&1; then
  pass "certified-operators catalog source is available"
else
  fail "certified-operators catalog source is unavailable"
fi

default_storage_classes=$(oc get storageclass \
  -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
  2>/dev/null || true)
if [[ -n $default_storage_classes ]]; then
  pass "default StorageClass is available: $(paste -sd, <<<"$default_storage_classes")"
else
  fail "no default StorageClass is configured for PostgreSQL PVCs"
fi

check_package_channel() {
  local package_name=$1
  local required_channel=$2
  local channels

  if ! channels=$(oc get packagemanifest "$package_name" -n openshift-marketplace \
    -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' 2>/dev/null); then
    fail "operator package $package_name is unavailable (check catalog and entitlement)"
    return
  fi

  if grep -Fxq "$required_channel" <<<"$channels"; then
    pass "$package_name provides channel $required_channel"
  else
    fail "$package_name does not provide required channel $required_channel"
  fi
}

check_package_channel openshift-gitops-operator gitops-1.21
check_package_channel openshift-cert-manager-operator stable-v1.19
check_package_channel servicemeshoperator3 stable-3.4
check_package_channel rhbk-operator stable-v26.6
check_package_channel rhcl-operator stable
check_package_channel openshift-external-secrets-operator stable-v1.2
check_package_channel cloudnative-pg stable-v1
check_package_channel opentelemetry-product stable
check_package_channel tempo-product stable

check_existing_subscription() {
  local package_name=$1
  local required_channel=$2
  local records

  records=$(oc get subscriptions.operators.coreos.com -A \
    -o go-template='{{range .items}}{{if eq .spec.name "'"$package_name"'"}}{{.metadata.namespace}}{{"\t"}}{{.metadata.name}}{{"\t"}}{{.spec.channel}}{{"\n"}}{{end}}{{end}}' \
    2>/dev/null || true)

  while IFS=$'\t' read -r namespace subscription channel; do
    [[ -z $namespace ]] && continue
    if [[ $channel == "$required_channel" ]]; then
      pass "existing $namespace/$subscription already uses $required_channel"
    else
      fail "existing $namespace/$subscription uses $channel; required channel is $required_channel"
    fi
  done <<<"$records"
}

check_existing_subscription openshift-gitops-operator gitops-1.21
check_existing_subscription openshift-cert-manager-operator stable-v1.19
check_existing_subscription servicemeshoperator3 stable-3.4
check_existing_subscription rhbk-operator stable-v26.6
check_existing_subscription rhcl-operator stable
check_existing_subscription openshift-external-secrets-operator stable-v1.2
check_existing_subscription cloudnative-pg stable-v1
check_existing_subscription opentelemetry-product stable
check_existing_subscription tempo-product stable

if ((failures > 0)); then
  echo "preflight failed with $failures issue(s); no cluster changes were made" >&2
  exit 1
fi

echo "preflight passed; the cluster is ready for bootstrap"
