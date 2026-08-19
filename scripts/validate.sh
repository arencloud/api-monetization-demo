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
import hashlib
import pathlib
import re
import stat
import yaml

uninstall_path = pathlib.Path("scripts/uninstall.sh")
uninstall_script = uninstall_path.read_text(encoding="utf-8")
if not uninstall_path.stat().st_mode & stat.S_IXUSR:
    raise SystemExit("scripts/uninstall.sh must remain executable")
required_uninstall_fragments = (
    "UNINSTALL_DELETE_TIMEOUT_SECONDS",
    "UNINSTALL_FINALIZER_TIMEOUT_SECONDS",
    "UNINSTALL_NAMESPACE_TIMEOUT_SECONDS",
    "delete_with_finalizer_recovery()",
    "sweep_terminating_namespace()",
    'if [[ -z $(jq -r \'.metadata.deletionTimestamp // empty\' <<<"$object_json") ]]',
    'oc replace --raw "/api/v1/namespaces/$namespace/finalize"',
    "dscinitializations.dscinitialization.opendatahub.io",
    "redhat-ods-applications",
    "redhat-ods-monitoring",
    "api-monetization-api-owners",
    "is_demo_namespace()",
    "PersistentVolume $volume from $claim_namespace",
    "Operator CRDs and the integrated image registry are retained intentionally",
)
for fragment in required_uninstall_fragments:
    if fragment not in uninstall_script:
        raise SystemExit(
            f"uninstall recovery contract is missing required behavior: {fragment}"
        )
for forbidden_fragment in (
    "oc delete namespace --all",
    "oc delete namespaces --all",
    "oc delete customresourcedefinition",
    "oc delete crd",
):
    if forbidden_fragment in uninstall_script:
        raise SystemExit(
            f"uninstall must not use broad destructive cleanup: {forbidden_fragment}"
        )

with open("bootstrap/root/application.yaml", encoding="utf-8") as stream:
    root = yaml.safe_load(stream)
expected = (
    root["spec"]["source"]["repoURL"],
    root["spec"]["source"]["targetRevision"],
)

with open("bootstrap/openshift-gitops/subscription.yaml", encoding="utf-8") as stream:
    gitops_subscription = yaml.safe_load(stream)
gitops_spec = gitops_subscription.get("spec", {})
if (
    gitops_spec.get("name") != "openshift-gitops-operator"
    or gitops_spec.get("channel") != "latest"
    or gitops_spec.get("source") != "redhat-operators"
    or gitops_spec.get("sourceNamespace") != "openshift-marketplace"
    or gitops_spec.get("installPlanApproval") != "Automatic"
    or "startingCSV" in gitops_spec
):
    raise SystemExit(
        "OpenShift GitOps must automatically track the latest channel head without startingCSV"
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

with open("gitops/applications/gateway.yaml", encoding="utf-8") as stream:
    gateway_application = yaml.safe_load(stream)
hostname_ignores = {
    item.get("name")
    for item in gateway_application.get("spec", {}).get("ignoreDifferences", [])
    if item.get("group") == "gateway.networking.k8s.io"
    and item.get("kind") == "HTTPRoute"
    and "/spec/hostnames" in item.get("jsonPointers", [])
}
required_hostname_ignores = {
    "inventory-api-key", "inventory-jwt", "payments-api-key", "payments-jwt",
    "ai-chat-api-key", "ai-chat-jwt", "ai-chat-api-key-preflight",
    "ai-chat-jwt-preflight",
}
if not required_hostname_ignores.issubset(hostname_ignores):
    raise SystemExit(
        "Gateway Application must preserve cluster-generated HTTPRoute hostnames: "
        f"{required_hostname_ignores - hostname_ignores}"
    )

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

with open("operators/openshift-ai/subscription.yaml", encoding="utf-8") as stream:
    openshift_ai_subscription = yaml.safe_load(stream)
openshift_ai_spec = openshift_ai_subscription.get("spec", {})
if (
    openshift_ai_spec.get("name") != "rhods-operator"
    or openshift_ai_spec.get("channel") != "stable-3.x"
    or openshift_ai_spec.get("source") != "redhat-operators"
    or openshift_ai_spec.get("startingCSV") != "rhods-operator.3.4.3"
):
    raise SystemExit("OpenShift AI Operator subscription is not pinned to the tested 3.4.3 lane")

with open("operators/rhdh/subscription.yaml", encoding="utf-8") as stream:
    rhdh_subscription = yaml.safe_load(stream)
rhdh_spec = rhdh_subscription.get("spec", {})
if (
    rhdh_spec.get("name") != "rhdh"
    or rhdh_spec.get("channel") != "fast-1.10"
    or rhdh_spec.get("source") != "redhat-operators"
    or rhdh_spec.get("sourceNamespace") != "openshift-marketplace"
    or rhdh_spec.get("installPlanApproval") != "Automatic"
    or "startingCSV" in rhdh_spec
):
    raise SystemExit("RHDH must track automatic 1.10 z-stream updates on fast-1.10")

with open("operators/devspaces/subscription.yaml", encoding="utf-8") as stream:
    devspaces_subscription = yaml.safe_load(stream)
devspaces_spec = devspaces_subscription.get("spec", {})
if (
    devspaces_subscription.get("metadata", {}).get("namespace") != "openshift-operators"
    or devspaces_spec.get("name") != "devspaces"
    or devspaces_spec.get("channel") != "stable"
    or devspaces_spec.get("source") != "redhat-operators"
    or devspaces_spec.get("sourceNamespace") != "openshift-marketplace"
    or devspaces_spec.get("installPlanApproval") != "Automatic"
    or "startingCSV" in devspaces_spec
):
    raise SystemExit("OpenShift Dev Spaces must automatically track the stable channel head")

with open("gitops/applications/devspaces.yaml", encoding="utf-8") as stream:
    devspaces_application = yaml.safe_load(stream)
devspaces_sync_options = (
    devspaces_application.get("spec", {})
    .get("syncPolicy", {})
    .get("syncOptions", [])
)
if "CreateNamespace=true" not in devspaces_sync_options:
    raise SystemExit("OpenShift Dev Spaces must create its destination namespace before reconciliation")

with open("platform/developer-hub/dynamic-plugins.yaml", encoding="utf-8") as stream:
    dynamic_plugins = yaml.safe_load(stream)
plugin_by_package = {
    plugin["package"]: plugin for plugin in dynamic_plugins.get("plugins", [])
}
expected_kuadrant_plugins = {
    "@kuadrant/kuadrant-backstage-plugin-backend-dynamic@v0.4.0":
        "sha512-OOkfAbnFxuOkBjvQMUqkd/TtP/yrXr15yQ/Xel880kdgZk39CPlQzVdOS3VXmcLa/Y9toI9nTbyCNqtXAD2C/g==",
    "@kuadrant/kuadrant-backstage-plugin-frontend@v0.4.0":
        "sha512-ewW/eOoHcK8MqmhyGzFQvnU8yQkvRpQxhb/GLZbAyWwWpmA/zju2qwFWXx49eBcy9RIlfO2rwS8sQC7do3dfGA==",
}
for package, integrity in expected_kuadrant_plugins.items():
    plugin = plugin_by_package.get(package, {})
    if plugin.get("disabled") is not False or plugin.get("integrity") != integrity:
        raise SystemExit(f"{package}: Kuadrant plugin version or integrity is not reproducibly pinned")

for package in (
    "./dynamic-plugins/dist/backstage-plugin-kubernetes",
    "./dynamic-plugins/dist/backstage-plugin-kubernetes-backend-dynamic",
    "./dynamic-plugins/dist/backstage-community-plugin-topology",
):
    if plugin_by_package.get(package, {}).get("disabled") is not False:
        raise SystemExit(f"{package}: Dev Spaces topology integration must be enabled")

kuadrant_frontend = (
    plugin_by_package["@kuadrant/kuadrant-backstage-plugin-frontend@v0.4.0"]
    .get("pluginConfig", {}).get("dynamicPlugins", {}).get("frontend", {})
    .get("internal.plugin-kuadrant", {})
)
kuadrant_routes = kuadrant_frontend.get("dynamicRoutes", [])
kuadrant_route_paths = {route.get("path") for route in kuadrant_routes}
for forbidden_route in (
    "/kuadrant/my-api-keys",
    "/kuadrant/api-key-approval",
    "/kuadrant/api-keys/:namespace/:name",
):
    if forbidden_route in kuadrant_route_paths:
        raise SystemExit(f"{forbidden_route}: raw API-key workflow must not be exposed in RHDH")
kuadrant_root = next(
    (route for route in kuadrant_routes if route.get("path") == "/kuadrant"),
    {},
)
if kuadrant_root.get("menuItem"):
    raise SystemExit("the technical Kuadrant root must not appear in consumer navigation")
if any(
    mount.get("importName") == "EntityKuadrantApiKeyManagementTab"
    for mount in kuadrant_frontend.get("mountPoints", [])
):
    raise SystemExit("catalog entities must not expose direct Kuadrant API-key management")

frontend_plugin_path = pathlib.Path(
    "platform/developer-hub/arencloud-rhdh-policy-catalog-dynamic-0.1.6.tgz"
)
frontend_plugin_package = (
    "/opt/app-root/src/local-plugins/"
    "arencloud-rhdh-policy-catalog-dynamic-0.1.6.tgz"
)
frontend_plugin = plugin_by_package.get(frontend_plugin_package, {})
if (
    frontend_plugin.get("disabled") is not False
    or frontend_plugin.get("integrity")
    != "sha512-Um1Vu1snxx733lux3R2+IJCtfMWC404J6QYIdTXk0NGDuTDqmJ51XzX2H2HBpCLzm0F56rUyTqOKMXf6l3ci7Q=="
):
    raise SystemExit("effective-policy RHDH plugin is not checksum-pinned")
frontend_config = (
    frontend_plugin.get("pluginConfig", {})
    .get("dynamicPlugins", {})
    .get("frontend", {})
    .get("arencloud.rhdh-policy-catalog", {})
)
if frontend_config.get("apiFactories") != [{"importName": "oidcAuthApiFactory"}]:
    raise SystemExit("RHDH monetization UI must register its generic OIDC API factory")
devspaces_mount = next(
    (
        mount for mount in frontend_config.get("mountPoints", [])
        if mount.get("mountPoint") == "entity.page.overview/cards"
        and mount.get("importName") == "EntityDevSpacesCard"
    ),
    {},
)
devspaces_condition = devspaces_mount.get("config", {}).get("if", {}).get("allOf", [])
if {"isKind": "component"} not in devspaces_condition or {
    "hasAnnotation": "github.com/project-slug"
} not in devspaces_condition:
    raise SystemExit("RHDH API-owner Components must expose their Dev Spaces action")
if not frontend_plugin_path.is_file() or frontend_plugin_path.stat().st_size >= 350_000:
    raise SystemExit("effective-policy plugin artifact is missing or too large for its ConfigMap")
if hashlib.sha256(frontend_plugin_path.read_bytes()).hexdigest() != (
    "77e335655bc281ce1b1612e53a43f684cb03a65775cd3bdee7814debffd2aedf"
):
    raise SystemExit("effective-policy plugin artifact checksum changed; rebuild and review it")

backend_plugin_path = pathlib.Path(
    "platform/developer-hub/arencloud-rhdh-monetization-backend-dynamic-0.1.4.tgz"
)
backend_plugin_package = (
    "/opt/app-root/src/local-plugins/"
    "arencloud-rhdh-monetization-backend-dynamic-0.1.4.tgz"
)
backend_plugin = plugin_by_package.get(backend_plugin_package, {})
if (
    backend_plugin.get("disabled") is not False
    or backend_plugin.get("integrity")
    != "sha512-hJ/Mmw87jleNPOjvJWsYsR6BoJjEijcvYPCVOhg0F8NpFpDs5TeMkAJ2KoFCAWMhLs+B8DBqteRl2OOc4rbmUw=="
):
    raise SystemExit("monetization RHDH backend plugin is not checksum-pinned")
if not backend_plugin_path.is_file() or backend_plugin_path.stat().st_size >= 700_000:
    raise SystemExit("monetization backend artifact is missing or too large for its ConfigMap")
if hashlib.sha256(backend_plugin_path.read_bytes()).hexdigest() != (
    "7f8641e3c040c8ecb03132f91181e380eb2df030bf14595e85972072aaafc0d9"
):
    raise SystemExit("monetization backend artifact checksum changed; rebuild and review it")
if frontend_plugin_path.stat().st_size + backend_plugin_path.stat().st_size >= 1_000_000:
    raise SystemExit("combined RHDH plugin artifacts exceed the ConfigMap safety budget")

configured_routes = []
for plugin in dynamic_plugins.get("plugins", []):
    frontends = (
        plugin.get("pluginConfig", {})
        .get("dynamicPlugins", {})
        .get("frontend", {})
    )
    for frontend in frontends.values():
        configured_routes.extend(
            route.get("path") for route in frontend.get("dynamicRoutes", [])
        )
if configured_routes.count("/kuadrant/api-products") != 1:
    raise SystemExit("exactly one frontend plugin must own /kuadrant/api-products")
if configured_routes.count("/billing") != 1:
    raise SystemExit("exactly one frontend plugin must own /billing")
if configured_routes.count("/monetized-apis") != 1:
    raise SystemExit("exactly one frontend plugin must own /monetized-apis")

with open("platform/developer-hub/app-config.yaml", encoding="utf-8") as stream:
    rhdh_config = yaml.safe_load(stream)
apis_menu = (
    rhdh_config.get("dynamicPlugins", {}).get("frontend", {})
    .get("default.main-menu-items", {}).get("menuItems", {})
    .get("default.apis", {})
)
if apis_menu.get("to") != "monetized-apis" or apis_menu.get("enabled") is not True:
    raise SystemExit("RHDH's top-level APIs menu must open the entitlement-aware explorer")
if rhdh_config.get("signInPage") != "oidc":
    raise SystemExit("RHDH must use the Keycloak OIDC sign-in page")
resolvers = (
    rhdh_config.get("auth", {}).get("providers", {}).get("oidc", {})
    .get("production", {}).get("signIn", {}).get("resolvers", [])
)
if resolvers != [{"resolver": "oidcSubClaimMatchingKeycloakUserId"}]:
    raise SystemExit("RHDH must use the non-bypass Keycloak user-ID sign-in resolver")
if not rhdh_config.get("permission", {}).get("enabled"):
    raise SystemExit("RHDH permission framework must be enabled for Kuadrant RBAC")
conditional_policy_path = rhdh_config.get("permission", {}).get("rbac", {}).get("conditionalPoliciesFile")
if conditional_policy_path != "/opt/app-root/etc/rbac-conditional-policies.yaml":
    raise SystemExit("RHDH must load its source-controlled conditional RBAC policy")
devspaces_environment = (
    rhdh_config.get("scaffolder", {})
    .get("defaultEnvironment", {})
    .get("parameters", {})
    .get("devSpacesBaseUrl")
)
if devspaces_environment != "${DEV_SPACES_URL}":
    raise SystemExit("RHDH scaffolder must consume the discovered Dev Spaces URL")
if rhdh_config.get("apiMonetization", {}).get("devSpacesBaseUrl") != "${DEV_SPACES_URL}":
    raise SystemExit("RHDH backend must consume the discovered Dev Spaces URL")
kubernetes_config = rhdh_config.get("kubernetes", {})
clusters = kubernetes_config.get("clusterLocatorMethods", [{}])[0].get("clusters", [])
if not any(
    cluster.get("authProvider") == "serviceAccount"
    and cluster.get("serviceAccountToken") == "${K8S_SERVICE_ACCOUNT_TOKEN}"
    for cluster in clusters
):
    raise SystemExit("RHDH and Kuadrant must consume a cluster-generated ServiceAccount credential")
custom_resources = {
    (resource.get("group"), resource.get("apiVersion"), resource.get("plural"))
    for resource in kubernetes_config.get("customResources", [])
}
if ("org.eclipse.che", "v2", "checlusters") not in custom_resources:
    raise SystemExit("RHDH topology must discover the OpenShift Dev Spaces CheCluster")
catalog_location_targets = {
    location.get("target")
    for location in rhdh_config.get("catalog", {}).get("locations", [])
}
expected_golden_path_targets = {
    "https://github.com/arencloud/api-monetization-demo/blob/"
    "${GITOPS_SOURCE_REVISION}/golden-paths/api-interface/template.yaml",
    "https://github.com/arencloud/api-monetization-demo/blob/"
    "${GITOPS_SOURCE_REVISION}/golden-paths/camel-api-integration/template.yaml",
}
if not expected_golden_path_targets.issubset(catalog_location_targets):
    raise SystemExit(
        "RHDH Golden Path locations must use the exact GitOps commit revision"
    )

rhdh_rbac = pathlib.Path("platform/developer-hub/rbac-policy.csv").read_text()
consumer_catalog_allow = "p, role:default/api-consumer, catalog.entity.read, read, allow"
if consumer_catalog_allow in rhdh_rbac:
    raise SystemExit("RHDH consumers must not receive an unconditional catalog read")
conditional_policy = yaml.safe_load(
    pathlib.Path("platform/developer-hub/rbac-conditional-policies.yaml").read_text()
)
if (
    conditional_policy.get("roleEntityRef") != "role:default/api-consumer"
    or conditional_policy.get("pluginId") != "catalog"
    or conditional_policy.get("permissionMapping") != ["read"]
    or conditional_policy.get("conditions", {}).get("rule") != "IS_ENTITY_KIND"
    or conditional_policy.get("conditions", {}).get("params", {}).get("kinds") != ["API", "Group"]
):
    raise SystemExit("RHDH consumers must be restricted to APIs and their owner groups")
for permission, action in (
    ("api-monetization.subscription.create.own", "create"),
    ("api-monetization.subscription.update.own", "update"),
    ("api-monetization.subscription.delete.own", "delete"),
):
    expected = f"p, role:default/api-consumer, {permission}, {action}, allow"
    if expected not in rhdh_rbac:
        raise SystemExit(f"RHDH consumers are missing {permission}")
for forbidden in (
    "kuadrant.apikey.create",
    "kuadrant.apikey.update",
    "kuadrant.apikey.delete",
    "kuadrant.apikey.approve",
):
    if forbidden in rhdh_rbac:
        raise SystemExit("all RHDH users must subscribe instead of directly mutating APIKey resources")

with open("platform/developer-hub/kuadrant-access.yaml", encoding="utf-8") as stream:
    rhdh_access = [resource for resource in yaml.safe_load_all(stream) if resource]
rhdh_kuadrant_role = next(
    resource for resource in rhdh_access
    if resource.get("kind") == "ClusterRole"
    and resource.get("metadata", {}).get("name") == "api-monetization-rhdh-kuadrant"
)
devportal_rules = {
    tuple(rule.get("resources", [])): set(rule.get("verbs", []))
    for rule in rhdh_kuadrant_role.get("rules", [])
    if "devportal.kuadrant.io" in rule.get("apiGroups", [])
}
if devportal_rules != {
    ("apiproducts",): {"get", "list", "watch", "create", "delete", "patch", "update"},
    ("apiproducts/status",): {"get", "patch", "update"},
}:
    raise SystemExit("RHDH must manage products without direct API-key resource access")
if any(
    resource.get("kind") in {"Role", "ClusterRole"}
    and any("secrets" in rule.get("resources", []) for rule in resource.get("rules", []))
    for resource in rhdh_access
):
    raise SystemExit("RHDH's Kuadrant integration must not read credential Secrets")

with open("platform/developer-hub/backstage.yaml", encoding="utf-8") as stream:
    backstage = yaml.safe_load(stream)
with open("platform/developer-hub/service-account-token.yaml", encoding="utf-8") as stream:
    rhdh_service_account_token = yaml.safe_load(stream)
if (
    rhdh_service_account_token.get("type") != "kubernetes.io/service-account-token"
    or rhdh_service_account_token.get("data") is not None
    or rhdh_service_account_token.get("stringData") is not None
    or rhdh_service_account_token.get("metadata", {}).get("annotations", {}).get(
        "kubernetes.io/service-account.name"
    ) != "api-monetization-rhdh"
):
    raise SystemExit("RHDH's Kubernetes credential must be generated by the cluster, never stored in Git")
with open("platform/developer-hub/database.yaml", encoding="utf-8") as stream:
    rhdh_database = yaml.safe_load(stream)
if rhdh_database.get("spec", {}).get("imageName") != (
    "ghcr.io/cloudnative-pg/postgresql:17.11-standard-trixie@"
    "sha256:91e0de662d53895a45f1396f4ee1a75daeb0c26fc87853afc9c8f43e01fdaa21"
):
    raise SystemExit("RHDH PostgreSQL 17 image must be digest-pinned")
if backstage.get("spec", {}).get("database", {}).get("enableLocalDb") is not False:
    raise SystemExit("RHDH must use its operator-managed external CloudNativePG database")
if backstage.get("spec", {}).get("flavours") != []:
    raise SystemExit("RHDH Lightspeed and other default flavours must remain disabled")
pod_spec = backstage.get("spec", {}).get("deployment", {}).get("patch", {}).get("spec", {}).get("template", {}).get("spec", {})
if pod_spec.get("serviceAccountName") != "api-monetization-rhdh" or pod_spec.get("automountServiceAccountToken") is not True:
    raise SystemExit("RHDH must use its dedicated in-cluster Kuadrant service account")
backstage_container = next(
    (container for container in pod_spec.get("containers", []) if container.get("name") == "backstage-backend"),
    {},
)
expected_token_env = {
    "name": "K8S_SERVICE_ACCOUNT_TOKEN",
    "valueFrom": {
        "secretKeyRef": {
            "name": "api-monetization-rhdh-service-account-token",
            "key": "token",
        }
    },
}
if expected_token_env not in backstage_container.get("env", []):
    raise SystemExit("RHDH must map the cluster-generated token into Kuadrant's required setting")
runtime_config = pathlib.Path("platform/developer-hub/runtime-config.yaml").read_text()
if (
    "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" not in runtime_config
    or "cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt" not in runtime_config
):
    raise SystemExit("RHDH's trusted bundle must include the OpenShift Kubernetes API CA")
runtime_resources = [
    resource for resource in yaml.safe_load_all(runtime_config) if resource
]
runtime_role = next(
    resource for resource in runtime_resources
    if resource.get("kind") == "Role"
    and resource.get("metadata", {}).get("name") == "api-monetization-rhdh-runtime-config"
)
runtime_job = next(
    resource for resource in runtime_resources
    if resource.get("kind") == "Job"
    and resource.get("metadata", {}).get("name") == "api-monetization-rhdh-runtime-config"
)
if not any(
    "jobs" in rule.get("resources", [])
    and "api-monetization-rhdh-runtime-config" in rule.get("resourceNames", [])
    and "get" in rule.get("verbs", [])
    for rule in runtime_role.get("rules", [])
):
    raise SystemExit("RHDH runtime discovery must read only its own Argo-annotated Job")
runtime_command = "\n".join(
    runtime_job["spec"]["template"]["spec"]["containers"][0].get("args", [])
)
for required_fragment in (
    'api-monetization.demo/source-revision',
    '^[0-9a-f]{40}$',
    '--from-literal="GITOPS_SOURCE_REVISION=$gitops_source_revision"',
):
    if required_fragment not in runtime_command:
        raise SystemExit(
            f"RHDH runtime discovery is missing Git revision behavior {required_fragment}"
        )
plugin_volume = next(
    (
        volume for volume in pod_spec.get("volumes", [])
        if volume.get("name") == "api-monetization-rhdh-local-plugins"
    ),
    {},
)
plugin_installer = next(
    (
        container for container in pod_spec.get("initContainers", [])
        if container.get("name") == "install-dynamic-plugins"
    ),
    {},
)
if plugin_volume.get("configMap", {}).get("name") != "api-monetization-rhdh-local-plugins":
    raise SystemExit("RHDH local plugin ConfigMap is not mounted")
for plugin_path, plugin_package in (
    (frontend_plugin_path, frontend_plugin_package),
    (backend_plugin_path, backend_plugin_package),
):
    if not any(
        mount.get("mountPath") == plugin_package
        and mount.get("subPath") == plugin_path.name
        and mount.get("readOnly") is True
        for mount in plugin_installer.get("volumeMounts", [])
    ):
        raise SystemExit(f"RHDH plugin installer cannot read {plugin_path.name}")
extra_envs = backstage.get("spec", {}).get("application", {}).get("extraEnvs", {}).get("envs", [])
if {"name": "NODE_EXTRA_CA_CERTS", "value": "/opt/app-root/etc/router-ca.crt"} not in extra_envs:
    raise SystemExit("RHDH must trust the discovered OpenShift router CA for Keycloak OIDC")

expected_commercial_products = {
    "inventory-api-product.yaml": "inventory",
    "inventory-jwt-api-product.yaml": "inventory",
    "payments-api-product.yaml": "payments",
    "payments-jwt-api-product.yaml": "payments",
    "ai-chat-api-product.yaml": "ai-chat",
    "ai-chat-jwt-api-product.yaml": "ai-chat",
}
for product_file in pathlib.Path("platform/gateway").glob("*-api-product.yaml"):
    product = yaml.safe_load(product_file.read_text())
    annotations = product.get("metadata", {}).get("annotations", {})
    owner = annotations.get("backstage.io/owner")
    if owner != "group:default/api-owners":
        raise SystemExit(f"{product_file}: APIProduct must declare its RHDH catalog owner")
    expected_product = expected_commercial_products.get(product_file.name)
    if expected_product and annotations.get("monetization.arencloud.com/product") != expected_product:
        raise SystemExit(f"{product_file}: APIProduct is not linked to its commercial subscription")

with open("platform/ai-model/serving-runtime.yaml", encoding="utf-8") as stream:
    ai_runtime = yaml.safe_load(stream)
with open("platform/ai-model/inference-service.yaml", encoding="utf-8") as stream:
    ai_service = yaml.safe_load(stream)
runtime_image = ai_runtime["spec"]["containers"][0]["image"]
predictor_model = ai_service["spec"]["predictor"]["model"]
storage_uri = predictor_model.get("storageUri", "")
if not runtime_image.startswith("registry.redhat.io/rhaii/vllm-cpu-rhel9@sha256:"):
    raise SystemExit("OpenShift AI CPU serving image must be a digest-pinned Red Hat image")
if not re.fullmatch(r"hf://Qwen/Qwen2\.5-0\.5B-Instruct:[0-9a-f]{40}", storage_uri):
    raise SystemExit("OpenShift AI model must use the approved, revision-pinned Hugging Face URI")
if (
    ai_service.get("metadata", {}).get("annotations", {}).get(
        "serving.kserve.io/deploymentMode"
    ) != "Standard"
    or predictor_model.get("runtime") != ai_runtime["metadata"]["name"]
):
    raise SystemExit("OpenShift AI InferenceService deployment mode or runtime reference is invalid")
ai_annotations = ai_service.get("metadata", {}).get("annotations", {})
if (
    ai_annotations.get("sidecar.istio.io/inject") != "true"
    or ai_annotations.get("sidecar.istio.io/rewriteAppHTTPProbers") != "true"
):
    raise SystemExit("OpenShift AI InferenceService must use the documented Service Mesh sidecar annotations")

with open("platform/gateway/ai-chat-token-rate-limits.yaml", encoding="utf-8") as stream:
    token_policies = [resource for resource in yaml.safe_load_all(stream) if resource]
expected_token_limits = {
    "free": 1000,
    "payg": 10000,
    "developer": 1000000,
    "business": 50000000,
}
expected_token_targets = {"ai-chat-api-key", "ai-chat-jwt"}
actual_token_targets = set()
for policy in token_policies:
    if policy.get("apiVersion") != "kuadrant.io/v1alpha1" or policy.get("kind") != "TokenRateLimitPolicy":
        raise SystemExit("AI token quota must use the RHCL TokenRateLimitPolicy API")
    target = policy["spec"]["targetRef"]
    actual_token_targets.add(target["name"])
    limits = policy["spec"]["limits"]
    counter_expression = (
        "auth.identity.subscription"
        if target["name"] == "ai-chat-api-key"
        else "auth.kuadrant.subscription"
    )
    for plan, expected_limit in expected_token_limits.items():
        plan_limit = limits.get(plan, {})
        rates = plan_limit.get("rates", [])
        if rates != [{"limit": expected_limit, "window": "720h"}]:
            raise SystemExit(f"{policy['metadata']['name']}: {plan} token quota does not match the commercial plan")
        if plan_limit.get("counters") != [{"expression": counter_expression}]:
            raise SystemExit(f"{policy['metadata']['name']}: {plan} token quota is not isolated by subscription identity")
        if plan_limit.get("when") != [{"predicate": f'auth.kuadrant.plan == "{plan}"'}]:
            raise SystemExit(f"{policy['metadata']['name']}: {plan} token quota does not select the RHCL plan metadata")
if actual_token_targets != expected_token_targets:
    raise SystemExit(f"AI token policies do not cover both credential routes: {actual_token_targets}")

with open("platform/gateway/ai-chat-auth-policies.yaml", encoding="utf-8") as stream:
    ai_auth_policies = [resource for resource in yaml.safe_load_all(stream) if resource]
for policy in ai_auth_policies:
    if policy.get("metadata", {}).get("name") not in {"ai-chat-api-key", "ai-chat-jwt"}:
        continue
    expected_filter_name = (
        "identity" if policy["metadata"]["name"] == "ai-chat-api-key" else "kuadrant"
    )
    response_properties = (
        policy.get("spec", {}).get("rules", {}).get("response", {})
        .get("success", {}).get("filters", {}).get(expected_filter_name, {})
        .get("json", {}).get("properties", {})
    )
    expected_properties = (
        {
            "userid": {"expression": 'auth.identity.metadata.annotations["secret.kuadrant.io/user-id"]'},
            "subscription": {"selector": "auth.metadata.subscription.id"},
        }
        if policy["metadata"]["name"] == "ai-chat-api-key"
        else {
            "customer": {"selector": "auth.metadata.subscription.customerId"},
            "plan": {"selector": "auth.metadata.subscription.plan"},
            "subscription": {"selector": "auth.metadata.subscription.id"},
        }
    )
    if response_properties != expected_properties:
        raise SystemExit(f"{policy['metadata']['name']}: AuthPolicy must publish customer, plan, and subscription metadata for RHCL token accounting")

with open("platform/gateway/ai-chat-routes.yaml", encoding="utf-8") as stream:
    ai_routes = [resource for resource in yaml.safe_load_all(stream) if resource]
preflight_route_names = {"ai-chat-api-key-preflight", "ai-chat-jwt-preflight"}
for route in ai_routes:
    route_name = route.get("metadata", {}).get("name")
    rules = route.get("spec", {}).get("rules", [])
    if route_name in preflight_route_names:
        matches = [match for rule in rules for match in rule.get("matches", [])]
        filters = [item for rule in rules for item in rule.get("filters", [])]
        if not any(
            match.get("method") == "OPTIONS"
            and match.get("path", {}).get("value") == "/v1/chat/completions"
            for match in matches
        ):
            raise SystemExit(f"{route_name}: portable browser preflight route is missing")
        header_sets = {
            header.get("name", "").lower(): header.get("value")
            for item in filters
            for header in item.get("responseHeaderModifier", {}).get("set", [])
        }
        if (
            header_sets.get("access-control-allow-origin") != "*"
            or "Authorization" not in header_sets.get("access-control-allow-headers", "")
        ):
            raise SystemExit(f"{route_name}: portable non-cookie CORS headers are incomplete")

preflight_policies = {
    policy.get("metadata", {}).get("name"): policy
    for policy in ai_auth_policies
    if policy.get("metadata", {}).get("name") in preflight_route_names
}
if set(preflight_policies) != preflight_route_names:
    raise SystemExit("Both AI Chat credential routes require an explicit preflight AuthPolicy")
for name, policy in preflight_policies.items():
    authentication = policy.get("spec", {}).get("rules", {}).get("authentication", {})
    if authentication != {"browser-preflight": {"anonymous": {}}}:
        raise SystemExit(f"{name}: only browser OPTIONS preflight may be anonymous")

with open("platform/gateway/openshift-routes.yaml", encoding="utf-8") as stream:
    gateway_routes = [resource for resource in yaml.safe_load_all(stream) if resource]
for route in gateway_routes:
    if route.get("metadata", {}).get("annotations", {}).get(
        "haproxy.router.openshift.io/timeout"
    ) != "180s":
        raise SystemExit(f"{route['metadata']['name']}: OpenShift Route timeout must accommodate CPU model inference")

with open("platform/gateway/ai-chat-plan-policy.yaml", encoding="utf-8") as stream:
    ai_plan_policy = yaml.safe_load(stream)
for plan in ai_plan_policy["spec"]["plans"]:
    if "monthly" in plan.get("limits", {}):
        raise SystemExit("AI PlanPolicy must leave monthly enforcement to TokenRateLimitPolicy")
with open("platform/gateway/ai-chat-jwt-rate-limits.yaml", encoding="utf-8") as stream:
    ai_jwt_request_policy = yaml.safe_load(stream)
if any(len(limit.get("rates", [])) != 1 for limit in ai_jwt_request_policy["spec"]["limits"].values()):
    raise SystemExit("AI JWT RateLimitPolicy must enforce only request burst protection")

promoted_applications = {
    "control": "monetization-control",
    "ai-chat": "ai-chat-api",
    "inventory": "inventory-api",
    "payments": "payments-api",
}
with open("gitops/applications/developer-hub.yaml", encoding="utf-8") as stream:
    developer_hub_application = yaml.safe_load(stream)
developer_hub_kustomize = (
    developer_hub_application.get("spec", {}).get("source", {}).get("kustomize", {})
)
if (
    developer_hub_kustomize.get("commonAnnotationsEnvsubst") is not True
    or developer_hub_kustomize.get("commonAnnotations", {}).get(
        "api-monetization.demo/source-revision"
    ) != "${ARGOCD_APP_REVISION}"
):
    raise SystemExit(
        "Developer Hub must inject its resolved Git commit into Golden Path discovery"
    )
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
    hook_delete_policy = job.get("metadata", {}).get("annotations", {}).get(
        "argocd.argoproj.io/hook-delete-policy", ""
    )
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
    if "HookSucceeded" not in hook_delete_policy or "HookFailed" in hook_delete_policy:
        raise SystemExit(
            f"{application_directory}: failed promotion hooks must remain visible for diagnosis"
        )
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
    "Accepted billable units (current month)",
    "Rate-limited attempts (selected range)",
    "Billable overage units",
    "Connectivity Link decisions by credential",
    "Gateway responses by HTTP status",
    "Usage, allowance, and hard quota",
    "Revenue by customer and plan",
    "AI Chat token attribution",
    "AI Chat tokens consumed and remaining",
    "AI Chat rejected requests",
    "Projected AI revenue (EUR)",
}
if not required_panels.issubset(panel_titles):
    raise SystemExit(f"Grafana dashboard is missing panels: {required_panels - panel_titles}")
dashboard_queries = "\n".join(
    target.get("expr", "")
    for panel in dashboard["panels"]
    for target in panel.get("targets", [])
)
for metric in (
    "monetization_billable_units",
    "monetization_included_units",
    "monetization_overage_units",
    "monetization_monthly_quota_requests",
    "monetization_projected_revenue_euros",
    "monetization_ai_prompt_tokens",
    "monetization_ai_completion_tokens",
    "authorized_calls",
    "limited_calls",
    "istio_requests_total",
):
    if metric not in dashboard_queries:
        raise SystemExit(f"Grafana dashboard does not query {metric}")
if 'instance=~".*:15090"' not in dashboard_queries:
    raise SystemExit("Grafana gateway query must select the Envoy metrics port to avoid duplicate scrapes")

ai_demo_script = pathlib.Path("scripts/ai-demo.sh").read_text(encoding="utf-8")
for required_fragment in (
    "subscription_id",
    "tokenratelimitpolicy.kuadrant.io",
    "Free token quota (HTTP 429)",
    '"plan":"developer"',
    "already-issued JWT",
    "cancel_if_present",
):
    if required_fragment not in ai_demo_script:
        raise SystemExit(f"AI demo automation is missing {required_fragment}")

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

for product in ("inventory", "payments", "ai-chat"):
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

with open("platform/secrets/demo/inventory-api-key.yaml", encoding="utf-8") as stream:
    demo_secret_resources = [resource for resource in yaml.safe_load_all(stream) if resource]
demo_external_secret = next(
    resource for resource in demo_secret_resources if resource.get("kind") == "ExternalSecret"
)
demo_secret_metadata = (
    demo_external_secret.get("spec", {}).get("target", {}).get("template", {}).get("metadata", {})
)
if demo_secret_metadata.get("labels", {}).get("devportal.kuadrant.io/apiproduct") != "inventory-api":
    raise SystemExit("The reproducible API key Secret must retain its Kuadrant APIProduct label")
if demo_secret_metadata.get("annotations", {}).get("secret.kuadrant.io/user-id") != "demo-company":
    raise SystemExit("The reproducible API key Secret must retain its Kuadrant consumer identity")

auth_policies = []
for product in ("inventory", "payments", "ai-chat"):
    with open(f"platform/gateway/{product}-auth-policies.yaml", encoding="utf-8") as stream:
        auth_policies.extend(yaml.safe_load_all(stream))
for policy in auth_policies:
    if policy.get("metadata", {}).get("name", "").endswith("-preflight"):
        continue
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

for product in ("inventory", "payments", "ai-chat"):
    jwt_policy = next(
        policy for policy in auth_policies if policy.get("metadata", {}).get("name") == f"{product}-jwt"
    )
    jwt_rules = jwt_policy.get("spec", {}).get("rules", {})
    jwt_authentication = jwt_rules.get("authentication", {}).get("keycloak", {}).get("jwt", {})
    if jwt_authentication != {
        "issuerUrl": "https://keycloak-api-monetization.apps.invalid/realms/api-monetization"
    }:
        raise SystemExit(f"{product}: JWT verification must use the portable Keycloak OIDC issuer placeholder")
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
for required_identity_fragment in (
    'run_kcadm delete "users/$admin_user_id/groups/$consumer_group_id"',
    'run_kcadm update "users/$developer_user_id/groups/$consumer_group_id"',
):
    if required_identity_fragment not in identity_script:
        raise SystemExit(
            "Keycloak identity reconciliation must keep elevated Golden Path users "
            "out of the consumer-only catalog policy"
        )
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

mapfile -t go_packages < <(
  go list ./... | grep -v '/node_modules/'
)
go test "${go_packages[@]}"
go vet "${go_packages[@]}"

python3 - <<'PY'
import pathlib
import yaml

for pattern in ("*.yaml", "*.yml"):
    for path in pathlib.Path(".").rglob(pattern):
        if any(part in {"node_modules", "dist", "dist-dynamic"} for part in path.parts):
            continue
        for resource in yaml.safe_load_all(path.read_text(encoding="utf-8")):
            if not isinstance(resource, dict) or resource.get("kind") != "Secret":
                continue
            service_account_token = (
                resource.get("type") == "kubernetes.io/service-account-token"
                and not resource.get("data")
                and not resource.get("stringData")
            )
            if not service_account_token:
                raise SystemExit(f"{path}: plaintext Kubernetes Secret resources are not allowed")
PY

if rg -n --glob '!**/node_modules/**' --glob '*.yaml' --glob '*.yml' 'image:[[:space:]]*[^[:space:]]+:latest([[:space:]]|$)' .; then
  echo "error: container images must not use the latest tag" >&2
  exit 1
fi

if rg -n --glob '!**/node_modules/**' --glob '*.yaml' --glob '*.yml' $'\t' .; then
  echo "error: YAML files must not contain tabs" >&2
  exit 1
fi

if rg -n --glob '!**/node_modules/**' --glob '*.yaml' --glob '*.yml' --glob '*.md' '[[:blank:]]+$' .; then
  echo "error: text files must not contain trailing whitespace" >&2
  exit 1
fi

./scripts/validate-golden-paths.py

echo "validated $package_count Kustomize packages"
