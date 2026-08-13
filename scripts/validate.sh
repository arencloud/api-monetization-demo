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

promoted_applications = {
    "control": "monetization-control",
    "inventory": "inventory-api",
    "payments": "payments-api",
}
for application_directory, workload_name in promoted_applications.items():
    with open(f"gitops/applications/{application_directory}.yaml", encoding="utf-8") as stream:
        application = yaml.safe_load(stream)
    kustomize = application.get("spec", {}).get("source", {}).get("kustomize", {})
    if (
        kustomize.get("commonAnnotationsEnvsubst") is not True
        or kustomize.get("commonAnnotations", {}).get(
            "api-monetization.demo/source-revision"
        ) != "${ARGOCD_APP_REVISION}"
    ):
        raise SystemExit(
            f"{application_directory}: Argo CD must inject the reconciled Git commit into build resources"
        )

    with open(f"applications/{application_directory}/source-build.yaml", encoding="utf-8") as stream:
        resources = [resource for resource in yaml.safe_load_all(stream) if resource]
    role = next(resource for resource in resources if resource.get("kind") == "Role")
    job = next(resource for resource in resources if resource.get("kind") == "Job")
    container = job["spec"]["template"]["spec"]["containers"][0]
    env = {item["name"]: item for item in container.get("env", [])}
    source_revision_field = (
        env.get("SOURCE_REVISION", {})
        .get("valueFrom", {})
        .get("fieldRef", {})
        .get("fieldPath")
    )
    command = "\n".join(container.get("command", []) + container.get("args", []))
    if source_revision_field != "metadata.annotations['api-monetization.demo/source-revision']":
        raise SystemExit(f"{application_directory}: source build does not consume the Argo CD revision")
    for required_fragment in (
        '--commit="$SOURCE_REVISION"',
        'Failed|Error|Cancelled',
        'status.output.to.imageDigest',
        'immutable_tag="git-${SOURCE_REVISION:0:12}"',
        'oc tag "$app@$digest" "$app:$immutable_tag"',
    ):
        if required_fragment not in command:
            raise SystemExit(
                f"{application_directory}: source build is missing promotion behavior {required_fragment}"
            )
    image_rules = [
        rule for rule in role.get("rules", [])
        if "image.openshift.io" in rule.get("apiGroups", [])
    ]
    if not any(
        "imagestreams" in rule.get("resources", [])
        and "update" in rule.get("verbs", [])
        and workload_name in rule.get("resourceNames", [])
        for rule in image_rules
    ) or not any(
        "imagestreamtags" in rule.get("resources", [])
        and "get" in rule.get("verbs", [])
        for rule in image_rules
    ):
        raise SystemExit(f"{application_directory}: build promotion RBAC is incomplete")

promotion_status_script = pathlib.Path("scripts/build-promotion-status.sh").read_text(encoding="utf-8")
for required_fragment in (
    ".status.sync.revision",
    ".spec.revision.git.commit",
    ".status.output.to.imageDigest",
    "imagestreamtag/$build_config:$immutable_tag",
    "all running application images have verified immutable Git provenance",
):
    if required_fragment not in promotion_status_script:
        raise SystemExit(f"build promotion verification is missing {required_fragment}")

with open("platform/observability/api-monetization.json", encoding="utf-8") as stream:
    dashboard = json.load(stream)
if dashboard.get("uid") != "api-monetization" or not dashboard.get("panels"):
    raise SystemExit("Grafana dashboard is missing its UID or panels")
panel_titles = {panel.get("title") for panel in dashboard["panels"]}
required_panels = {
    "Accepted billable requests (current month)",
    "Rate-limited attempts (selected range)",
    "Billable overage requests",
    "Connectivity Link decisions by credential",
    "Gateway responses by HTTP status",
    "Usage, allowance, and hard quota",
    "Revenue by customer and plan",
}
if not required_panels.issubset(panel_titles):
    raise SystemExit(f"Grafana dashboard is missing panels: {required_panels - panel_titles}")
dashboard_queries = "\n".join(
    target.get("expr", "")
    for panel in dashboard["panels"]
    for target in panel.get("targets", [])
)
for metric in (
    "monetization_billable_requests",
    "monetization_overage_requests",
    "monetization_monthly_quota_requests",
    "monetization_projected_revenue_euros",
    "authorized_calls",
    "limited_calls",
    "istio_requests_total",
):
    if metric not in dashboard_queries:
        raise SystemExit(f"Grafana dashboard does not query {metric}")
if 'instance=~".*:15090"' not in dashboard_queries:
    raise SystemExit("Grafana gateway query must select the Envoy metrics port to avoid duplicate scrapes")

with open("operators/grafana/subscription.yaml", encoding="utf-8") as stream:
    grafana_subscription = yaml.safe_load(stream)
grafana_subscription_spec = grafana_subscription.get("spec", {})
if (
    grafana_subscription_spec.get("name") != "grafana-operator"
    or grafana_subscription_spec.get("channel") != "v5"
    or grafana_subscription_spec.get("source") != "community-operators"
    or grafana_subscription_spec.get("startingCSV") != "grafana-operator.v5.24.0"
):
    raise SystemExit("Grafana Operator subscription is not pinned to the tested v5.24 lane")

with open("platform/observability/grafana.yaml", encoding="utf-8") as stream:
    grafana_resources = [resource for resource in yaml.safe_load_all(stream) if resource]
grafana = next(resource for resource in grafana_resources if resource["kind"] == "Grafana")
datasource = next(resource for resource in grafana_resources if resource["kind"] == "GrafanaDatasource")
dashboard_resource = next(resource for resource in grafana_resources if resource["kind"] == "GrafanaDashboard")
instance_labels = grafana["metadata"]["labels"]
selector = datasource["spec"]["instanceSelector"]["matchLabels"]
if not all(instance_labels.get(key) == value for key, value in selector.items()):
    raise SystemExit("Grafana datasource selector does not match the managed instance")
if dashboard_resource["spec"]["instanceSelector"]["matchLabels"] != selector:
    raise SystemExit("Grafana dashboard and datasource do not select the same instance")
if dashboard_resource["spec"].get("configMapRef") != {
    "name": "api-monetization-grafana-dashboard",
    "key": "api-monetization.json",
}:
    raise SystemExit("GrafanaDashboard does not import the generated dashboard ConfigMap")
datasource_model = datasource["spec"]["datasource"]
if (
    datasource_model.get("url") != "https://thanos-querier.openshift-monitoring.svc:9091"
    or datasource_model.get("isDefault") is not True
    or datasource_model.get("jsonData", {}).get("httpHeaderName1") != "Authorization"
    or datasource_model.get("secureJsonData", {}).get("httpHeaderValue1") != "Bearer ${token}"
):
    raise SystemExit("Grafana OpenShift Thanos datasource authentication is incomplete")
if not grafana["spec"].get("disableDefaultAdminSecret"):
    raise SystemExit("Grafana must use the externally generated administrator credential")
grafana_config = grafana["spec"].get("config", {})
oauth = grafana_config.get("auth.generic_oauth", {})
if (
    oauth.get("enabled") != "true"
    or oauth.get("client_id") != "api-monetization-grafana"
    or oauth.get("role_attribute_strict") != "true"
    or oauth.get("use_pkce") != "true"
    or oauth.get("tls_client_ca") != "/etc/grafana/oauth/router-ca.crt"
    or oauth.get("tls_skip_verify_insecure") != "false"
):
    raise SystemExit("Grafana Keycloak OAuth or TLS verification is incomplete")
role_expression = oauth.get("role_attribute_path", "")
if not all(
    value in role_expression
    for value in ("monetization-admin", "monetization-developer", "Admin", "Viewer")
):
    raise SystemExit("Grafana OAuth role mapping does not enforce the Keycloak role boundary")
grafana_container = grafana["spec"]["deployment"]["spec"]["template"]["spec"]["containers"][0]
grafana_env = {item["name"]: item for item in grafana_container.get("env", [])}
if (
    grafana_env.get("GRAFANA_OAUTH_CLIENT_SECRET", {})
    .get("valueFrom", {})
    .get("secretKeyRef", {})
    .get("name")
    != "api-monetization-grafana-oauth"
    or grafana_env.get("GRAFANA_ROOT_URL", {})
    .get("valueFrom", {})
    .get("configMapKeyRef", {})
    .get("name")
    != "api-monetization-grafana-oauth-config"
    or grafana_env.get("KEYCLOAK_ORIGIN", {})
    .get("valueFrom", {})
    .get("configMapKeyRef", {})
    .get("name")
    != "api-monetization-grafana-oauth-config"
):
    raise SystemExit("Grafana OAuth runtime values are not sourced from managed secrets/config")

with open("platform/observability/grafana-secret-store.yaml", encoding="utf-8") as stream:
    secret_store_resources = [resource for resource in yaml.safe_load_all(stream) if resource]
secret_store = next(
    resource for resource in secret_store_resources if resource["kind"] == "SecretStore"
)
kubernetes_provider = secret_store.get("spec", {}).get("provider", {}).get("kubernetes", {})
if (
    secret_store.get("metadata", {}).get("namespace") != "api-monetization-observability"
    or secret_store.get("metadata", {}).get("annotations", {}).get(
        "argocd.argoproj.io/sync-wave"
    ) != "-5"
    or kubernetes_provider.get("remoteNamespace") != "api-monetization-identity"
    or kubernetes_provider.get("auth", {}).get("serviceAccount", {}).get("name")
    != "api-monetization-secret-reader"
    or kubernetes_provider.get("server", {}).get("caProvider", {}).get("name")
    != "kube-root-ca.crt"
):
    raise SystemExit("Grafana cross-namespace OAuth secret store is incomplete")
with open("platform/observability/kustomization.yaml", encoding="utf-8") as stream:
    observability_kustomization = yaml.safe_load(stream)
if "grafana-secret-store.yaml" not in observability_kustomization.get("resources", []):
    raise SystemExit("Grafana SecretStore must be ordered in the Observability Argo application")

with open("platform/observability/grafana-credentials.yaml", encoding="utf-8") as stream:
    grafana_credential_resources = [resource for resource in yaml.safe_load_all(stream) if resource]
grafana_oauth_secret = next(
    resource
    for resource in grafana_credential_resources
    if resource.get("kind") == "ExternalSecret"
    and resource.get("metadata", {}).get("name") == "api-monetization-grafana-oauth"
)
oauth_secret_spec = grafana_oauth_secret.get("spec", {})
oauth_remote_ref = oauth_secret_spec.get("data", [{}])[0].get("remoteRef", {})
if (
    oauth_secret_spec.get("secretStoreRef")
    != {"kind": "SecretStore", "name": "api-monetization-identity"}
    or oauth_remote_ref.get("key") != "grafana-keycloak-client"
    or oauth_remote_ref.get("property") != "client-secret"
    or oauth_secret_spec.get("target", {}).get("deletionPolicy") != "Retain"
):
    raise SystemExit("Grafana OAuth client secret is not mirrored from the identity namespace")

for product in ("inventory", "payments"):
    with open(f"applications/{product}/openapi.yaml", encoding="utf-8") as stream:
        openapi = yaml.safe_load(stream)
    if not str(openapi.get("openapi", "")).startswith("3.") or not openapi.get("paths"):
        raise SystemExit(f"{product}: OpenAPI document is incomplete")
    if openapi.get("servers", [{}])[0].get("url") != "https://api-monetization.invalid":
        raise SystemExit(f"{product}: OpenAPI document is missing its portable server placeholder")

    with open(f"applications/{product}/service.yaml", encoding="utf-8") as stream:
        product_service = yaml.safe_load(stream)
    service_ports = {
        port.get("name"): (port.get("port"), port.get("targetPort"))
        for port in product_service.get("spec", {}).get("ports", [])
    }
    if service_ports.get("http-openapi") != (8082, "openapi"):
        raise SystemExit(f"{product}: documentation-only Service port 8082 is missing")

    with open(f"platform/gateway/{product}-api-product.yaml", encoding="utf-8") as stream:
        api_product = yaml.safe_load(stream)
    expected_openapi_url = f"http://{product}-api.api-monetization-apps.svc.cluster.local:8082/openapi.yaml"
    if api_product.get("spec", {}).get("documentation", {}).get("openAPISpecURL") != expected_openapi_url:
        raise SystemExit(f"{product}: APIProduct must fetch OpenAPI from the documentation-only port")

with open("platform/gateway/openapi-readiness.yaml", encoding="utf-8") as stream:
    openapi_readiness = yaml.safe_load(stream)
readiness_annotations = openapi_readiness.get("metadata", {}).get("annotations", {})
readiness_script = openapi_readiness["spec"]["template"]["spec"]["containers"][0]["command"][-1]
if (
    readiness_annotations.get("argocd.argoproj.io/hook") != "Sync"
    or ":8082/openapi.yaml" not in readiness_script
):
    raise SystemExit("Gateway sync must wait for the fetchable OpenAPI document before APIProduct wave 40")

with open("platform/gateway/gateway.yaml", encoding="utf-8") as stream:
    gateway = yaml.safe_load(stream)
if gateway.get("spec", {}).get("gatewayClassName") != "istio":
    raise SystemExit("Gateway must use the project Service Mesh GatewayClass")

with open("platform/namespaces/namespaces.yaml", encoding="utf-8") as stream:
    namespaces = [resource for resource in yaml.safe_load_all(stream) if resource]
kuadrant_namespace = next(
    resource for resource in namespaces if resource.get("metadata", {}).get("name") == "kuadrant-system"
)
if kuadrant_namespace.get("metadata", {}).get("labels", {}).get("istio-discovery") != "enabled":
    raise SystemExit("The project Istio control plane must discover the RHCL system namespace")

with open("platform/connectivity-link/kuadrant.yaml", encoding="utf-8") as stream:
    kuadrant = yaml.safe_load(stream)
if kuadrant.get("spec", {}).get("mtls") != {
    "enable": True,
    "authorino": True,
    "limitador": True,
}:
    raise SystemExit("RHCL mTLS must be enabled explicitly for Authorino and Limitador")

auth_policies = []
for product in ("inventory", "payments"):
    with open(f"platform/gateway/{product}-auth-policies.yaml", encoding="utf-8") as stream:
        auth_policies.extend(yaml.safe_load_all(stream))
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

for product in ("inventory", "payments"):
    jwt_policy = next(
        policy for policy in auth_policies if policy.get("metadata", {}).get("name") == f"{product}-jwt"
    )
    jwt_rules = jwt_policy.get("spec", {}).get("rules", {})
    jwt_authentication = jwt_rules.get("authentication", {}).get("keycloak", {}).get("jwt", {})
    if jwt_authentication != {
        "jwksUrl": "http://api-monetization-service.api-monetization-identity.svc.cluster.local:8080/realms/api-monetization/protocol/openid-connect/certs"
    }:
        raise SystemExit(f"{product}: JWT verification must use the internal Keycloak JWKS endpoint")
    jwt_issuer_patterns = (
        jwt_rules.get("authorization", {})
        .get("keycloak-issuer", {})
        .get("patternMatching", {})
        .get("patterns", [])
    )
    if not any(
        pattern.get("selector") == "auth.identity.iss"
        and pattern.get("operator") == "matches"
        and pattern.get("value")
        == r"^https://keycloak-api-monetization[.]apps[.][^/]+/realms/api-monetization$"
        for pattern in jwt_issuer_patterns
    ):
        raise SystemExit(f"{product}: JWT authorization must validate the portable external Keycloak issuer")

control_token_script = pathlib.Path("scripts/control-token.sh").read_text(encoding="utf-8")
if not all(
    value in control_token_script
    for value in (
        "keycloak_route=api-monetization-keycloak",
        "--cacert \"$route_ca_file\"",
        "--connect-to \"$keycloak_hostname:443:$router_hostname:443\"",
        '"https://$keycloak_hostname/realms/api-monetization/protocol/openid-connect/token"',
    )
) or "port-forward" in control_token_script:
    raise SystemExit("Automation tokens must be issued through the admitted HTTPS Keycloak Route")

with open("applications/control/rbac.yaml", encoding="utf-8") as stream:
    control_rbac = [resource for resource in yaml.safe_load_all(stream) if resource]
credential_role = next(
    resource
    for resource in control_rbac
    if resource.get("kind") == "Role"
    and resource.get("metadata", {}).get("name") == "monetization-credential-manager"
)
portal_artifact_rule = next(
    (
        rule
        for rule in credential_role.get("rules", [])
        if set(rule.get("resources", [])) == {"apikeyrequests", "apikeyapprovals"}
    ),
    None,
)
if not portal_artifact_rule or set(portal_artifact_rule.get("verbs", [])) != {
    "delete",
    "get",
    "list",
}:
    raise SystemExit("Credential cancellation needs least-privilege cleanup of RHCL request artifacts")

for product in ("inventory", "payments"):
    with open(f"platform/gateway/{product}-plan-policy.yaml", encoding="utf-8") as stream:
        plan_policy = yaml.safe_load(stream)
    plan_tiers = {plan["tier"]: plan for plan in plan_policy["spec"]["plans"]}
    payg = plan_tiers.get("payg", {}).get("limits", {})
    if payg.get("monthly") != 10000 or not any(
        limit.get("limit") == 100 and limit.get("window") == "1m"
        for limit in payg.get("custom", [])
    ):
        raise SystemExit(f"{product}: Pay-as-you-go API-key enforcement limits are incomplete")
    if plan_tiers.get("developer", {}).get("limits", {}).get("monthly") != 1000000:
        raise SystemExit(f"{product}: Developer hard quota must remain above its included allowance")

    with open(f"platform/gateway/{product}-jwt-rate-limits.yaml", encoding="utf-8") as stream:
        jwt_limits = yaml.safe_load(stream)["spec"]["limits"]
    if "payg" not in jwt_limits or not {
        (rate.get("limit"), rate.get("window"))
        for rate in jwt_limits["payg"].get("rates", [])
    }.issuperset({(100, "1m"), (10000, "720h")}):
        raise SystemExit(f"{product}: Pay-as-you-go JWT enforcement limits are incomplete")
    expected_jwt_quotas = {"free": 1000, "developer": 1000000, "business": 50000000}
    for tier, quota in expected_jwt_quotas.items():
        if (quota, "720h") not in {
            (rate.get("limit"), rate.get("window"))
            for rate in jwt_limits[tier].get("rates", [])
        }:
            raise SystemExit(f"{product}/{tier}: JWT hard quota is missing")

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
grafana_client_match = re.search(
    r"cat >/tmp/grafana-client.json <<JSON\n(.*?)\n[ \t]*JSON",
    identity_script,
    re.S,
)
if not grafana_client_match:
    raise SystemExit("Grafana Keycloak client definition is missing")
grafana_client = json.loads(grafana_client_match.group(1))
if (
    grafana_client.get("clientId") != "api-monetization-grafana"
    or grafana_client.get("publicClient") is not False
    or grafana_client.get("standardFlowEnabled") is not True
    or grafana_client.get("directAccessGrantsEnabled") is not False
    or grafana_client.get("redirectUris") != ["$GRAFANA_REDIRECT_URI"]
    or grafana_client.get("webOrigins") != ["$GRAFANA_ORIGIN"]
):
    raise SystemExit("Grafana Keycloak client is not a restricted confidential browser client")
grafana_role_mapper = next(
    (
        mapper
        for mapper in grafana_client.get("protocolMappers", [])
        if mapper.get("protocolMapper") == "oidc-usermodel-realm-role-mapper"
    ),
    None,
)
if not grafana_role_mapper or any(
    grafana_role_mapper.get("config", {}).get(field) != "true"
    for field in ("multivalued", "access.token.claim", "id.token.claim", "userinfo.token.claim")
):
    raise SystemExit("Grafana Keycloak client does not publish realm roles")

route_job = next(
    resource
    for resource in identity_resources
    if resource.get("kind") == "Job"
    and resource.get("metadata", {}).get("name") == "api-monetization-portal-route-config"
)
route_script = route_job["spec"]["template"]["spec"]["containers"][0]["command"][-1]
if not all(
    value in route_script
    for value in (
        "grafana-origin=$grafana_origin",
        "grafana-redirect-uri=$grafana_origin/login/generic_oauth",
    )
):
    raise SystemExit("Identity route discovery does not publish the exact Grafana callback")

with open("platform/service-mesh/peer-authentication.yaml", encoding="utf-8") as stream:
    peer_authentications = [resource for resource in yaml.safe_load_all(stream) if resource]
default_peer_authentication = next(
    resource for resource in peer_authentications if resource["metadata"]["name"] == "default"
)
if default_peer_authentication.get("spec", {}).get("mtls", {}).get("mode") != "STRICT":
    raise SystemExit("Application Service Mesh peer authentication must enforce STRICT mTLS")
for product in ("inventory", "payments"):
    peer_authentication = next(
        resource for resource in peer_authentications if resource["metadata"]["name"] == f"{product}-api"
    )
    peer_spec = peer_authentication.get("spec", {})
    if (
        peer_spec.get("selector", {}).get("matchLabels")
        != {"app.kubernetes.io/name": f"{product}-api"}
        or peer_spec.get("mtls", {}).get("mode") != "STRICT"
        or peer_spec.get("portLevelMtls") != {"8082": {"mode": "DISABLE"}}
    ):
        raise SystemExit(f"{product}: only the documentation port may bypass application mTLS")
PY

if unformatted=$(gofmt -l applications internal); [[ -n $unformatted ]]; then
  echo "error: Go files are not formatted:" >&2
  echo "$unformatted" >&2
  exit 1
fi

go test ./...
go vet ./...

python3 - <<'PY'
import pathlib
import yaml

for pattern in ("*.yaml", "*.yml"):
    for path in pathlib.Path(".").rglob(pattern):
        for resource in yaml.safe_load_all(path.read_text(encoding="utf-8")):
            if not resource or resource.get("kind") != "Secret":
                continue
            service_account_token = (
                resource.get("type") == "kubernetes.io/service-account-token"
                and not resource.get("data")
                and not resource.get("stringData")
            )
            if not service_account_token:
                raise SystemExit(f"{path}: plaintext Kubernetes Secret resources are not allowed")
PY

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
