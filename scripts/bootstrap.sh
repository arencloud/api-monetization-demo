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

echo "waiting for OLM to resolve the OpenShift GitOps subscription"
for attempt in $(seq 1 120); do
  installed_csv=$(oc get subscription openshift-gitops-operator \
    -n openshift-gitops-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  if [[ -n $installed_csv ]]; then
    echo "installed CSV: $installed_csv"
    break
  fi
  if ((attempt == 120)); then
    echo "error: timed out waiting for the OpenShift GitOps Operator" >&2
    exit 1
  fi
  sleep 5
done

echo "waiting for the default Argo CD server"
oc wait --for=condition=Available deployment/openshift-gitops-server \
  -n openshift-gitops --timeout=10m

echo "registering the API monetization root application"
oc apply -k bootstrap/root

echo "bootstrap complete; Argo CD now owns platform reconciliation"
