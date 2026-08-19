#!/usr/bin/env python3
"""Validate and reproducibly render the API-owner RHDH Golden Paths."""

from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
TEMPLATES = {
    "api-interface": ROOT / "golden-paths/api-interface/template.yaml",
    "camel-api-integration": ROOT / "golden-paths/camel-api-integration/template.yaml",
}
VALUES = {
    "name": "orders-edge",
    "displayName": "Orders Edge API",
    "description": "Golden Path validation API",
    "apiPath": "/orders",
    "owner": "group:default/api-owners",
    "lifecycle": "production",
    "approvalMode": "automatic",
    "publishStatus": "Draft",
    "freeRequestsPerMinute": "10",
    "freeMonthlyQuota": "1000",
    "developerRequestsPerMinute": "1000",
    "developerMonthlyQuota": "1000000",
    "repoOwner": "arencloud",
}
VALUE_EXPRESSION = re.compile(r"\$\{\{\s*values\.([A-Za-z0-9_]+)\s*\}\}")


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def run(command: list[str], cwd: pathlib.Path) -> None:
    subprocess.run(command, cwd=cwd, check=True)


def render_skeleton(source: pathlib.Path, destination: pathlib.Path) -> None:
    shutil.copytree(source, destination)
    for path in destination.rglob("*"):
        if not path.is_file() or ".github/workflows" in path.as_posix():
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue

        def substitute(match: re.Match[str]) -> str:
            key = match.group(1)
            if key not in VALUES:
                fail(f"{path}: unknown template value {key}")
            return VALUES[key]

        path.write_text(VALUE_EXPRESSION.sub(substitute, content), encoding="utf-8")


def assert_template(path: pathlib.Path) -> None:
    template = yaml.safe_load(path.read_text(encoding="utf-8"))
    if template.get("apiVersion") != "scaffolder.backstage.io/v1beta3" or template.get("kind") != "Template":
        fail(f"{path}: not an RHDH Software Template")
    spec = template.get("spec", {})
    if spec.get("owner") != "group:default/api-owners":
        fail(f"{path}: template must be owned by api-owners")
    if template.get("metadata", {}).get("annotations", {}).get("backstage.io/template-version") != "1.2.0":
        fail(f"{path}: template must expose the self-service publication release")
    actions = [step.get("action") for step in spec.get("steps", [])]
    if actions != ["fetch:template", "publish:github", "catalog:register"]:
        fail(f"{path}: must render, create a dedicated GitHub repository, and register it")
    sections = spec.get("parameters", [])
    repo_section = next((section for section in sections if section.get("title") == "Dedicated GitHub repository"), {})
    properties = repo_section.get("properties", {})
    if properties.get("repoOwner", {}).get("enum") != ["arencloud"]:
        fail(f"{path}: repository owner must match the Argo CD source allowlist")
    if properties.get("repoVisibility", {}).get("enum") != ["public"]:
        fail(f"{path}: portable catalog registration requires a public repository")
    if properties.get("githubToken", {}).get("ui:field") != "Secret":
        fail(f"{path}: GitHub token must use the scaffolder secret store")
    identity = sections[0].get("properties", {})
    if identity.get("publishStatus", {}).get("default") != "Draft":
        fail(f"{path}: owner-created products must default to Draft")
    publish = spec["steps"][1].get("input", {})
    if publish.get("repoUrl") != "github.com?owner=${{ parameters.repoOwner }}&repo=${{ parameters.name }}":
        fail(f"{path}: publish action does not create one repository per API")
    if publish.get("token") != "${{ secrets.githubToken }}":
        fail(f"{path}: publish action must consume, but never persist, the task token")
    output_links = spec.get("output", {}).get("links", [])
    devspaces_link = next(
        (link for link in output_links if link.get("title") == "Open in OpenShift Dev Spaces"),
        None,
    )
    expected_devspaces_link = (
        "/api/api-monetization/devspaces/open?"
        "owner=${{ parameters.repoOwner }}&repo=${{ parameters.name }}"
    )
    if not devspaces_link or devspaces_link.get("url") != expected_devspaces_link:
        fail(f"{path}: must return the validated Dev Spaces redirect")

    repository_link = next(
        (link for link in output_links if link.get("title") == "Dedicated GitHub repository"),
        {},
    ).get("url")
    publication_link = next(
        (link for link in output_links if link.get("title") == "Publish from the Component overview"),
        {},
    )
    expected_repository = "https://github.com/${{ parameters.repoOwner }}/${{ parameters.name }}"
    if repository_link != expected_repository:
        fail(f"{path}: repository link must not contain a Git transport suffix")
    if publication_link.get("entityRef") != "${{ steps.register.output.entityRef }}":
        fail(f"{path}: task output must direct the owner to governed publication")


def assert_platform_configuration() -> None:
    app_config = yaml.safe_load((ROOT / "platform/developer-hub/app-config.yaml").read_text(encoding="utf-8"))
    locations = {
        location.get("target")
        for location in app_config.get("catalog", {}).get("locations", [])
        if location.get("type") == "url"
    }
    expected = {
        "https://github.com/arencloud/api-monetization-demo/blob/main/golden-paths/api-interface/template.yaml",
        "https://github.com/arencloud/api-monetization-demo/blob/main/golden-paths/camel-api-integration/template.yaml",
    }
    if not expected.issubset(locations):
        fail("RHDH catalog does not register both Golden Paths from the delivery branch")
    github_integrations = app_config.get("integrations", {}).get("github", [])
    if not any(integration.get("host") == "github.com" for integration in github_integrations):
        fail("RHDH must recognize github.com for catalog and publish actions")
    devspaces_environment = (
        app_config.get("scaffolder", {})
        .get("defaultEnvironment", {})
        .get("parameters", {})
        .get("devSpacesBaseUrl")
    )
    if devspaces_environment != "${DEV_SPACES_URL}":
        fail("RHDH must inject the discovered Dev Spaces URL into every Golden Path")
    if app_config.get("apiMonetization", {}).get("devSpacesBaseUrl") != "${DEV_SPACES_URL}":
        fail("RHDH monetization backend must consume the discovered Dev Spaces URL")
    if app_config.get("apiMonetization", {}).get("publication", {}).get("githubOwner") != "arencloud":
        fail("RHDH publication must be restricted to the approved GitHub organization")
    custom_resources = {
        (resource.get("group"), resource.get("apiVersion"), resource.get("plural"))
        for resource in app_config.get("kubernetes", {}).get("customResources", [])
    }
    if ("org.eclipse.che", "v2", "checlusters") not in custom_resources:
        fail("RHDH topology must discover the Operator-managed CheCluster")

    dynamic_plugins = yaml.safe_load(
        (ROOT / "platform/developer-hub/dynamic-plugins.yaml").read_text(encoding="utf-8")
    )
    github_scaffolder = next(
        (
            plugin
            for plugin in dynamic_plugins.get("plugins", [])
            if plugin.get("package")
            == "./dynamic-plugins/dist/backstage-plugin-scaffolder-backend-module-github-dynamic"
        ),
        None,
    )
    if not github_scaffolder or github_scaffolder.get("disabled") is not False:
        fail("RHDH must enable the GitHub scaffolder module that provides publish:github")
    enabled_packages = {
        plugin.get("package")
        for plugin in dynamic_plugins.get("plugins", [])
        if plugin.get("disabled") is False
    }
    for package in (
        "./dynamic-plugins/dist/backstage-plugin-kubernetes",
        "./dynamic-plugins/dist/backstage-plugin-kubernetes-backend-dynamic",
        "./dynamic-plugins/dist/backstage-community-plugin-topology",
    ):
        if package not in enabled_packages:
            fail(f"RHDH must enable {package} for the Dev Spaces source editor")

    policy = (ROOT / "platform/developer-hub/rbac-policy.csv").read_text(encoding="utf-8")
    permissions = (
        ("scaffolder.template.parameter.read", "read"),
        ("scaffolder.template.step.read", "read"),
        ("scaffolder.action.execute", "use"),
        ("scaffolder.task.create", "create"),
        ("scaffolder.task.read", "read"),
        ("scaffolder.task.cancel", "use"),
    )
    for role in ("api-owner", "api-admin"):
        for permission, action in permissions:
            line = f"p, role:default/{role}, {permission}, {action}, allow"
            if line not in policy:
                fail(f"RHDH {role} is missing {permission}")
        for permission, action in (
            ("api-monetization.publication.read", "read"),
            ("api-monetization.publication.create", "create"),
        ):
            line = f"p, role:default/{role}, {permission}, {action}, allow"
            if line not in policy:
                fail(f"RHDH {role} is missing {permission}")
    consumer_lines = [line for line in policy.splitlines() if "role:default/api-consumer" in line]
    if any("scaffolder." in line or "catalog.location.create" in line for line in consumer_lines):
        fail("API consumers must not execute owner Golden Paths")
    if any("catalog.entity.read" in line for line in consumer_lines):
        fail("API consumers must not receive unconditional Component catalog access")
    conditional_policy = yaml.safe_load(
        (ROOT / "platform/developer-hub/rbac-conditional-policies.yaml").read_text(encoding="utf-8")
    )
    if (
        conditional_policy.get("roleEntityRef") != "role:default/api-consumer"
        or conditional_policy.get("permissionMapping") != ["read"]
        or conditional_policy.get("conditions", {}).get("rule") != "IS_ENTITY_KIND"
        or conditional_policy.get("conditions", {}).get("params", {}).get("kinds") != ["API", "Group"]
    ):
        fail("API consumers must see APIs and their owner groups through conditional RBAC")

    project = yaml.safe_load((ROOT / "gitops/applications/api-owner-project.yaml").read_text(encoding="utf-8"))
    spec = project.get("spec", {})
    if spec.get("sourceRepos") != ["https://github.com/arencloud/*.git"]:
        fail("API-owner AppProject source allowlist does not match the template organization")
    if spec.get("destinations") != [{"server": "https://kubernetes.default.svc", "namespace": "api-monetization-apps"}]:
        fail("API-owner AppProject must be confined to api-monetization-apps")
    allowed = {(item.get("group"), item.get("kind")) for item in spec.get("namespaceResourceWhitelist", [])}
    forbidden = {("", "Secret"), ("rbac.authorization.k8s.io", "Role"), ("rbac.authorization.k8s.io", "RoleBinding")}
    if allowed & forbidden or spec.get("clusterResourceWhitelist"):
        fail("API-owner repositories must not create secrets, RBAC, or cluster resources")

    access = list(yaml.safe_load_all(
        (ROOT / "platform/developer-hub/kuadrant-access.yaml").read_text(encoding="utf-8")
    ))
    publication_role = next(
        (resource for resource in access if resource and resource.get("kind") == "Role"
         and resource.get("metadata", {}).get("name") == "api-monetization-rhdh-publications"),
        None,
    )
    publication_binding = next(
        (resource for resource in access if resource and resource.get("kind") == "RoleBinding"
         and resource.get("metadata", {}).get("name") == "api-monetization-rhdh-publications"),
        None,
    )
    expected_verbs = {"get", "create", "patch"}
    role_rules = publication_role.get("rules", []) if publication_role else []
    if not any(
        rule.get("apiGroups") == ["argoproj.io"]
        and rule.get("resources") == ["applications"]
        and set(rule.get("verbs", [])) == expected_verbs
        for rule in role_rules
    ):
        fail("RHDH publication role must have only the required Argo CD Application verbs")
    if not publication_binding or publication_binding.get("roleRef", {}).get("name") != "api-monetization-rhdh-publications":
        fail("RHDH publication role must be bound in openshift-gitops")

    rendered = subprocess.check_output(
        ["oc", "kustomize", "gitops/applications"], cwd=ROOT, text=True
    )
    rendered_project = next(
        (
            resource
            for resource in yaml.safe_load_all(rendered)
            if isinstance(resource, dict)
            and resource.get("kind") == "AppProject"
            and resource.get("metadata", {}).get("name") == "api-monetization-api-owners"
        ),
        None,
    )
    if not rendered_project or rendered_project.get("spec", {}).get("sourceRepos") != [
        "https://github.com/arencloud/*.git"
    ]:
        fail("rendering must preserve the dedicated API-owner repository allowlist")


def assert_rendered_project(kind: str, project: pathlib.Path) -> None:
    unresolved = []
    for path in project.rglob("*"):
        if not path.is_file() or ".github/workflows" in path.as_posix():
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if "${{ values." in content:
            unresolved.append(str(path))
    if unresolved:
        fail(f"{kind}: unresolved template expressions in {', '.join(unresolved)}")

    subprocess.run(
        ["oc", "kustomize", "gitops"],
        cwd=project,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    application = yaml.safe_load((project / "bootstrap/argocd-application.yaml").read_text(encoding="utf-8"))
    app_spec = application.get("spec", {})
    if app_spec.get("project") != "api-monetization-api-owners":
        fail(f"{kind}: generated Application bypasses the restricted AppProject")
    if "automated" in app_spec.get("syncPolicy", {}):
        fail(f"{kind}: generated API repositories require reviewed promotion")
    if app_spec.get("destination", {}).get("namespace") != "api-monetization-apps":
        fail(f"{kind}: generated Application targets an unapproved namespace")

    devfile = yaml.safe_load((project / "devfile.yaml").read_text(encoding="utf-8"))
    if devfile.get("schemaVersion") != "2.2.2":
        fail(f"{kind}: generated project must provide a Dev Spaces devfile")
    commands = {
        command.get("id")
        for command in devfile.get("commands", [])
        if isinstance(command, dict)
    }
    if commands != {"test", "run"}:
        fail(f"{kind}: Dev Spaces must expose test and run commands")

    catalog_documents = list(
        yaml.safe_load_all((project / "catalog-info.yaml").read_text(encoding="utf-8"))
    )
    component = next(document for document in catalog_documents if document.get("kind") == "Component")
    if component.get("metadata", {}).get("annotations", {}).get("backstage.io/kubernetes-id") != "orders-edge":
        fail(f"{kind}: catalog Component is not mapped to its OpenShift workload")
    component_links = component.get("metadata", {}).get("links", [])
    devspaces_link = next(
        (link for link in component_links if link.get("title") == "Open in OpenShift Dev Spaces"),
        {},
    )
    if devspaces_link.get("url") != (
        "/api/api-monetization/devspaces/open?owner=arencloud&repo=orders-edge"
    ):
        fail(f"{kind}: catalog Component is missing its reusable Dev Spaces action")
    deployment = yaml.safe_load((project / "gitops/deployment.yaml").read_text(encoding="utf-8"))
    annotations = deployment.get("metadata", {}).get("annotations", {})
    if annotations.get("app.openshift.io/vcs-uri") != "https://github.com/arencloud/orders-edge.git":
        fail(f"{kind}: workload is missing its Dev Spaces Git source annotation")
    if annotations.get("app.openshift.io/vcs-ref") != "main":
        fail(f"{kind}: workload is missing its Dev Spaces Git branch annotation")
    if deployment.get("metadata", {}).get("labels", {}).get("backstage.io/kubernetes-id") != "orders-edge":
        fail(f"{kind}: workload is not discoverable by RHDH Topology")

    for suffix in ("api-key", "jwt"):
        if not (project / "gitops/api-products.yaml").read_text(encoding="utf-8").count(f"orders-edge-{suffix}"):
            fail(f"{kind}: generated project is missing the {suffix} product")

    routes = (project / "gitops/routes.yaml").read_text(encoding="utf-8")
    auth = (project / "gitops/auth-policies.yaml").read_text(encoding="utf-8")
    plans = (project / "gitops/plans.yaml").read_text(encoding="utf-8")
    if "api-monetization.invalid" not in routes or "jwt.api-monetization.invalid" not in routes:
        fail(f"{kind}: generated routes must use portable publication placeholders")
    api_products = (project / "gitops/api-products.yaml").read_text(encoding="utf-8")
    if api_products.count("svc.cluster.local:8082/openapi.yaml") != 2:
        fail(f"{kind}: both APIProducts must use the mesh-exempt documentation port")
    peer_authentication = yaml.safe_load(
        (project / "gitops/peer-authentication.yaml").read_text(encoding="utf-8")
    )
    if (
        peer_authentication.get("spec", {}).get("mtls", {}).get("mode") != "STRICT"
        or peer_authentication.get("spec", {}).get("portLevelMtls", {}).get("8082", {}).get("mode") != "DISABLE"
    ):
        fail(f"{kind}: API traffic must retain strict mTLS with only port 8082 exempted")
    for required in (
        "/internal/entitlements/", "/internal/entitlements/token/",
        "active-subscription", "x-monetization-customer", "x-monetization-plan",
    ):
        if required not in auth:
            fail(f"{kind}: generated AuthPolicies are missing {required}")
    for required in (
        'auth.kuadrant.plan == "free"', 'auth.kuadrant.plan == "developer"',
        "auth.kuadrant.customer",
    ):
        if required not in plans:
            fail(f"{kind}: generated JWT plan policy is missing {required}")

    if kind == "camel-api-integration":
        ET.parse(project / "pom.xml")
        pom = (project / "pom.xml").read_text(encoding="utf-8")
        route = (project / "src/main/resources/routes/integration.camel.yaml").read_text(encoding="utf-8")
        for required in ("3.33.3.redhat-00001", "quarkus-camel-bom", "camel-quarkus-yaml-dsl"):
            if required not in pom:
                fail(f"Camel project is missing {required}")
        if "platform-http:/orders" not in route or "bean:canonicalMapping" not in route:
            fail("Camel project does not render its mapping route")


def java_major() -> int | None:
    if not shutil.which("java"):
        return None
    result = subprocess.run(["java", "-version"], text=True, capture_output=True, check=False)
    match = re.search(r'version "(\d+)', result.stderr + result.stdout)
    return int(match.group(1)) if match else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", action="store_true", help="also compile and test both rendered projects")
    arguments = parser.parse_args()

    if not shutil.which("oc"):
        fail("oc is required")
    for path in TEMPLATES.values():
        assert_template(path)
    assert_platform_configuration()

    with tempfile.TemporaryDirectory(prefix="api-golden-paths-") as temporary:
        temporary_root = pathlib.Path(temporary)
        projects: dict[str, pathlib.Path] = {}
        for kind, template in TEMPLATES.items():
            project = temporary_root / kind
            render_skeleton(template.parent / "skeleton", project)
            assert_rendered_project(kind, project)
            projects[kind] = project

        if arguments.build:
            if not shutil.which("go"):
                fail("Go is required to build the API interface Golden Path")
            run(["go", "test", "./..."], projects["api-interface"])
            if not shutil.which("mvn"):
                fail("Maven is required to build the Camel Golden Path")
            major = java_major()
            if major is None or major < 21:
                fail(f"Java 21 or newer is required to build Red Hat Camel (found {major or 'none'})")
            run(["mvn", "-B", "test"], projects["camel-api-integration"])

    print("validated 2 API-owner Golden Paths and their generated GitOps projects")


if __name__ == "__main__":
    main()
