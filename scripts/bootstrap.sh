#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if [[ -n $(git status --porcelain) ]]; then
  echo "error: commit and push repository changes before bootstrap" >&2
  echo "Argo CD reads the configured remote repository, not this working tree." >&2
  exit 1
fi

read -r gitops_repo_url gitops_revision < <(
  python3 - <<'PY'
import yaml

with open("bootstrap/root/application.yaml", encoding="utf-8") as stream:
    application = yaml.safe_load(stream)
source = application["spec"]["source"]
print(source["repoURL"], source["targetRevision"])
PY
)

local_revision=$(git rev-parse HEAD)
remote_revision=$(git ls-remote --exit-code "$gitops_repo_url" \
  "refs/heads/$gitops_revision" 2>/dev/null | awk 'NR == 1 {print $1}')
if [[ -z $remote_revision ]]; then
  echo "error: cannot resolve branch $gitops_revision at $gitops_repo_url" >&2
  exit 1
fi
if [[ $local_revision != "$remote_revision" ]]; then
  echo "error: local HEAD $local_revision is not the published $gitops_revision revision" >&2
  echo "push the commit that should be reconciled before bootstrap" >&2
  exit 1
fi

./scripts/validate.sh
./scripts/preflight.sh

echo "installing the OpenShift GitOps Operator"
oc apply -k bootstrap/openshift-gitops

echo "waiting for the OpenShift GitOps CSV to succeed"
last_csv=""
for attempt in $(seq 1 120); do
  current_csv=$(oc get subscription openshift-gitops-operator \
    -n openshift-gitops-operator -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  if [[ -z $current_csv ]]; then
    current_csv=$(oc get subscription openshift-gitops-operator \
      -n openshift-gitops-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  fi

  if [[ -n $current_csv ]]; then
    csv_phase=$(oc get clusterserviceversion.operators.coreos.com "$current_csv" \
      -n openshift-gitops-operator -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ $current_csv != "$last_csv" ]]; then
      echo "OLM resolved CSV: $current_csv"
      last_csv=$current_csv
    fi
    if [[ $csv_phase == "Succeeded" ]]; then
      echo "CSV succeeded: $current_csv"
      break
    fi
    if [[ $csv_phase == "Failed" ]]; then
      echo "error: CSV $current_csv failed to install" >&2
      oc get clusterserviceversion.operators.coreos.com "$current_csv" \
        -n openshift-gitops-operator -o jsonpath='{range .status.conditions[*]}{.phase}{": "}{.message}{"\n"}{end}' \
        >&2 || true
      exit 1
    fi
  fi

  if ((attempt == 120)); then
    echo "error: timed out waiting for the OpenShift GitOps CSV to succeed" >&2
    oc describe subscription openshift-gitops-operator \
      -n openshift-gitops-operator >&2 || true
    [[ -n $current_csv ]] && oc describe clusterserviceversion.operators.coreos.com \
      "$current_csv" -n openshift-gitops-operator >&2 || true
    exit 1
  fi
  sleep 5
done

if [[ -z $current_csv ]]; then
  echo "error: OLM did not resolve an OpenShift GitOps CSV" >&2
  exit 1
fi

wait_for_resource() {
  local resource=$1
  local namespace=${2:-}
  local description=$3

  for attempt in $(seq 1 120); do
    if [[ -n $namespace ]]; then
      if oc get "$resource" -n "$namespace" >/dev/null 2>&1; then
        return 0
      fi
    elif oc get "$resource" >/dev/null 2>&1; then
      return 0
    fi

    if ((attempt == 120)); then
      echo "error: timed out waiting for $description to be created" >&2
      return 1
    fi
    sleep 5
  done
}

echo "waiting for the default Argo CD namespace"
wait_for_resource namespace/openshift-gitops "" "namespace openshift-gitops"

echo "waiting for the default Argo CD server deployment"
wait_for_resource deployment/openshift-gitops-server openshift-gitops \
  "deployment openshift-gitops/openshift-gitops-server"

echo "waiting for the default Argo CD server to become available"
oc wait --for=condition=Available deployment/openshift-gitops-server \
  -n openshift-gitops --timeout=10m

echo "granting the GitOps application controller cluster configuration access"
oc apply -f bootstrap/root/application-controller-cluster-role-binding.yaml

for attempt in $(seq 1 30); do
  controller_access=$(oc auth can-i '*' '*' --all-namespaces \
    --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller \
    2>/dev/null || true)
  if [[ $controller_access == "yes" ]]; then
    break
  fi
  if ((attempt == 30)); then
    echo "error: GitOps application controller did not receive cluster configuration access" >&2
    exit 1
  fi
  sleep 2
done

echo "registering the API monetization root application"
oc apply -k bootstrap/root

echo "bootstrap complete; Argo CD now owns platform reconciliation"
