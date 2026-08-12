#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc is required for Kustomize rendering" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 and PyYAML are required for YAML validation" >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required for application tests" >&2
  exit 1
fi

for script in scripts/*.sh; do
  bash -n "$script"
done

render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT

package_count=0
while IFS= read -r package; do
  package_count=$((package_count + 1))
  output_file="$render_dir/package-${package_count}.yaml"
  echo "rendering $package"
  oc kustomize "$package" >"$output_file"

  python3 - "$output_file" <<'PY'
import pathlib
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit("error: python3 PyYAML is required for validation") from exc

path = pathlib.Path(sys.argv[1])
for index, document in enumerate(yaml.safe_load_all(path.read_text()), start=1):
    if document is None:
        continue
    if not isinstance(document, dict):
        raise SystemExit(f"{path}: document {index} is not a YAML object")
    for field in ("apiVersion", "kind", "metadata"):
        if field not in document:
            raise SystemExit(f"{path}: document {index} is missing {field}")
    if not isinstance(document["metadata"], dict) or not document["metadata"].get("name"):
        raise SystemExit(f"{path}: document {index} is missing metadata.name")
PY
done < <(find applications bootstrap gitops operators platform -name kustomization.yaml -printf '%h\n' | sort)

python3 - <<'PY'
import subprocess
import json
import pathlib
import re
import yaml

with open("bootstrap/root/application.yaml", encoding="utf-8") as stream:
    root = yaml.safe_load(stream)
expected = (
    root["spec"]["source"]["repoURL"],
    root["spec"]["source"]["targetRevision"],
)

rendered = subprocess.check_output(
    ["oc", "kustomize", "gitops/applications"], text=True
)
for resource in yaml.safe_load_all(rendered):
    if not resource or resource.get("kind") != "Application":
        continue
    actual = (
        resource["spec"]["source"]["repoURL"],
        resource["spec"]["source"]["targetRevision"],
    )
    if actual != expected:
        name = resource["metadata"]["name"]
        raise SystemExit(
            f"{name}: child Git source {actual} does not match root source {expected}"
        )
    source_path = resource["spec"]["source"]["path"]
    if not __import__("pathlib").Path(source_path, "kustomization.yaml").is_file():
        raise SystemExit(f"{name}: source path {source_path} has no kustomization.yaml")

for build_file in pathlib.Path("applications").glob("*/build.yaml"):
    for resource in yaml.safe_load_all(build_file.read_text()):
        if not resource or resource.get("kind") != "BuildConfig":
            continue
        git_source = resource["spec"]["source"]["git"]
        actual = (git_source["uri"], git_source["ref"])
        if actual != expected:
            raise SystemExit(
                f"{build_file}: build Git source {actual} does not match root source {expected}"
            )

with open("platform/observability/api-monetization.json", encoding="utf-8") as stream:
    dashboard = json.load(stream)
if dashboard.get("uid") != "api-monetization" or not dashboard.get("panels"):
    raise SystemExit("Grafana dashboard is missing its UID or panels")

with open("applications/inventory/openapi.yaml", encoding="utf-8") as stream:
    openapi = yaml.safe_load(stream)
if not str(openapi.get("openapi", "")).startswith("3.") or not openapi.get("paths"):
    raise SystemExit("Inventory OpenAPI document is incomplete")
if openapi.get("servers", [{}])[0].get("url") != "https://api-monetization.invalid":
    raise SystemExit("Inventory OpenAPI document is missing its portable server placeholder")

with open("platform/gateway/gateway.yaml", encoding="utf-8") as stream:
    gateway = yaml.safe_load(stream)
if gateway.get("spec", {}).get("gatewayClassName") != "istio":
    raise SystemExit("Gateway must use the project Service Mesh GatewayClass")

with open("platform/gateway/inventory-auth-policies.yaml", encoding="utf-8") as stream:
    auth_policies = list(yaml.safe_load_all(stream))
for policy in auth_policies:
    rules = policy.get("spec", {}).get("rules", {})
    active = rules.get("authorization", {}).get("active-subscription", {})
    patterns = active.get("patternMatching", {}).get("patterns", [])
    if not any(
        pattern.get("selector") == "auth.metadata.subscription.status"
        and pattern.get("operator") == "eq"
        and pattern.get("value") == "active"
        for pattern in patterns
    ):
        name = policy.get("metadata", {}).get("name", "unknown")
        raise SystemExit(f"{name}: active subscription authorization is missing")

with open("platform/identity/portal-identity.yaml", encoding="utf-8") as stream:
    identity_resources = [resource for resource in yaml.safe_load_all(stream) if resource]
identity_job = next(
    resource
    for resource in identity_resources
    if resource.get("kind") == "Job"
    and resource.get("metadata", {}).get("name") == "api-monetization-portal-identity"
)
identity_script = identity_job["spec"]["template"]["spec"]["containers"][0]["command"][-1]
developer_client_match = re.search(
    r"cat >/tmp/developer-automation-client.json <<JSON\n(.*?)\n[ \t]*JSON",
    identity_script,
    re.S,
)
if not developer_client_match:
    raise SystemExit("developer automation Keycloak client definition is missing")
developer_client = json.loads(developer_client_match.group(1))
developer_audiences = {
    mapper.get("config", {}).get("included.custom.audience")
    for mapper in developer_client.get("protocolMappers", [])
}
if not {"monetization-control", "api-monetization"}.issubset(developer_audiences):
    raise SystemExit("developer automation client is missing a lifecycle-test audience")

with open("platform/service-mesh/peer-authentication.yaml", encoding="utf-8") as stream:
    peer_authentication = yaml.safe_load(stream)
if peer_authentication.get("spec", {}).get("mtls", {}).get("mode") != "STRICT":
    raise SystemExit("Application Service Mesh peer authentication must enforce STRICT mTLS")
PY

if unformatted=$(gofmt -l applications internal); [[ -n $unformatted ]]; then
  echo "error: Go files are not formatted:" >&2
  echo "$unformatted" >&2
  exit 1
fi

go test ./...
go vet ./...

if rg -n --glob '*.yaml' --glob '*.yml' '^kind:[[:space:]]*Secret[[:space:]]*$' .; then
  echo "error: plaintext Kubernetes Secret resources are not allowed" >&2
  exit 1
fi

if rg -n --glob '*.yaml' --glob '*.yml' 'image:[[:space:]]*[^[:space:]]+:latest([[:space:]]|$)' .; then
  echo "error: container images must not use the latest tag" >&2
  exit 1
fi

if rg -n --glob '*.yaml' --glob '*.yml' $'\t' .; then
  echo "error: YAML files must not contain tabs" >&2
  exit 1
fi

if rg -n --glob '*.yaml' --glob '*.yml' --glob '*.md' '[[:blank:]]+$' .; then
  echo "error: text files must not contain trailing whitespace" >&2
  exit 1
fi

echo "validated $package_count Kustomize packages"
