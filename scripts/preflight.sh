#!/usr/bin/env bash

set -Eeuo pipefail

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc is required" >&2
  exit 1
fi

failures=0
warnings=0

pass() {
  echo "PASS: $*"
}

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

warn() {
  echo "WARN: $*" >&2
  warnings=$((warnings + 1))
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

registry_state=$(oc get configs.imageregistry.operator.openshift.io cluster \
  -o jsonpath='{.spec.managementState}' 2>/dev/null || true)
case "$registry_state" in
  Managed)
    registry_uses_empty_dir=$(oc get configs.imageregistry.operator.openshift.io cluster \
      -o jsonpath='{.spec.storage.emptyDir}' 2>/dev/null || true)
    registry_storage_entries=$(oc get configs.imageregistry.operator.openshift.io cluster \
      -o go-template='{{len .spec.storage}}' 2>/dev/null || true)
    registry_deployment_available=$(oc get deployment/image-registry \
      -n openshift-image-registry \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
      2>/dev/null || true)
    registry_operator_available=$(oc get clusteroperator/image-registry \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
      2>/dev/null || true)
    registry_operator_degraded=$(oc get clusteroperator/image-registry \
      -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' \
      2>/dev/null || true)
    if [[ $registry_storage_entries == 0 ]]; then
      fail "integrated image registry is Managed but has no storage configuration"
    elif [[ -n $registry_uses_empty_dir ]]; then
      fail "integrated image registry uses non-persistent emptyDir storage; configure infrastructure-backed storage"
    elif [[ $registry_deployment_available == "True" && \
      $registry_operator_available == "True" && $registry_operator_degraded == "False" ]]; then
      registry_pvc=$(oc get configs.imageregistry.operator.openshift.io cluster \
        -o jsonpath='{.spec.storage.pvc.claim}' 2>/dev/null || true)
      if [[ -n $registry_pvc ]]; then
        registry_pvc_phase=$(oc get pvc "$registry_pvc" -n openshift-image-registry \
          -o jsonpath='{.status.phase}' 2>/dev/null || true)
        registry_pvc_size=$(oc get pvc "$registry_pvc" -n openshift-image-registry \
          -o jsonpath='{.status.capacity.storage}' 2>/dev/null || true)
        if [[ $registry_pvc_phase == "Bound" ]]; then
          pass "integrated image registry is Managed and ready with bound PVC $registry_pvc (${registry_pvc_size:-unknown size})"
        else
          fail "integrated image registry PVC $registry_pvc is not Bound"
        fi
      else
        pass "integrated image registry is Managed and ready with infrastructure-backed storage"
      fi
    else
      fail "integrated image registry is Managed but NOT READY"
    fi
    ;;
  Removed)
    fail "integrated image registry is Removed; configure persistent infrastructure storage and set it to Managed"
    ;;
  Unmanaged)
    fail "integrated image registry is Unmanaged; set it to Managed or Removed"
    ;;
  *)
    fail "could not determine the integrated image registry management state"
    ;;
esac

assigned_load_balancers=$(oc get services -A \
  -o go-template='{{range .items}}{{if eq .spec.type "LoadBalancer"}}{{if .status.loadBalancer.ingress}}{{.metadata.namespace}}{{"/"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' \
  2>/dev/null || true)
metallb_instances=$(oc get metallbs.metallb.io -A \
  -o go-template='{{range .items}}{{.metadata.namespace}}{{"/"}}{{.metadata.name}}{{"\n"}}{{end}}' \
  2>/dev/null || true)

if [[ -n $assigned_load_balancers ]]; then
  pass "external Service LoadBalancer assignment detected: $(paste -sd, <<<"$assigned_load_balancers"); the Gateway can retain its LoadBalancer Service"
elif [[ -n $metallb_instances ]]; then
  metallb_ready=false
  while IFS=/ read -r metallb_namespace metallb_name; do
    [[ -z $metallb_namespace ]] && continue
    controller_available=$(oc get deployment/controller -n "$metallb_namespace" \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
      2>/dev/null || true)
    speaker_desired=$(oc get daemonset/speaker -n "$metallb_namespace" \
      -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)
    speaker_ready=$(oc get daemonset/speaker -n "$metallb_namespace" \
      -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
    address_pools=$(oc get ipaddresspools.metallb.io -n "$metallb_namespace" \
      -o name 2>/dev/null || true)
    if [[ $controller_available == "True" && $speaker_desired =~ ^[1-9][0-9]*$ && \
      $speaker_desired == "$speaker_ready" && -n $address_pools ]]; then
      pass "MetalLB $metallb_namespace/$metallb_name is ready with an IP address pool; the Gateway can retain its LoadBalancer Service"
      metallb_ready=true
    fi
  done <<<"$metallb_instances"
  if [[ $metallb_ready != "true" ]]; then
    warn "MetalLB is installed but NOT READY to assign external Service IPs; the adaptive Gateway will fall back to ClusterIP plus OpenShift Routes unless MetalLB becomes ready during its probe"
  fi
else
  platform_type=$(oc get infrastructure cluster \
    -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || true)
  warn "no external Service LoadBalancer provider detected on platform ${platform_type:-unknown}: MetalLB is not installed and no LoadBalancer Service has an assigned ingress; the adaptive Gateway will use ClusterIP plus OpenShift Routes if its live probe also receives no address"
fi

if oc get ingresscontroller/default -n openshift-ingress-operator >/dev/null 2>&1; then
  pass "default OpenShift ingress controller is available for demo Routes"
else
  fail "default OpenShift ingress controller is unavailable"
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

if ((warnings > 0)); then
  echo "preflight passed with $warnings warning(s); review them above before bootstrap (non-required capabilities do not block this demo)"
else
  echo "preflight passed; the cluster is ready for bootstrap"
fi
