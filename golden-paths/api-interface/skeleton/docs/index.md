# ${{ values.displayName }}

${{ values.description }}

The public contract is stored in `openapi/openapi.yaml`. Requests enter through
Gateway API and Red Hat Connectivity Link before reaching the mesh-enabled
service. Both API-key and Red Hat build of Keycloak JWT entry points are
declared in GitOps.

## Ownership

- Catalog owner: `${{ values.owner }}`
- Lifecycle: `${{ values.lifecycle }}`
- Public path: `${{ values.apiPath }}`

