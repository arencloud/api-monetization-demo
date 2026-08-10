# ADR 0002: Secret and PostgreSQL operators

- Status: Accepted
- Date: 2026-08-10

## Context

Keycloak and the monetization services require durable PostgreSQL databases and
credentials that must not be committed to Git. The demo must install services by
Operator where an appropriate Operator exists and must remain deployable without
requiring a specific cloud secret backend.

## Decision

Use External Secrets Operator for Red Hat OpenShift 1.2 from the Red Hat Operator
catalog. It manages the external-secrets operand cluster-wide. Use the
Red Hat-certified CloudNativePG 1.30 Operator from the certified catalog for
PostgreSQL lifecycle management.

The self-contained demo overlay uses External Secrets password generators. Each
database, client, and API-key credential is created with `CreatedOnce`, an
immutable target, and orphan ownership. This avoids rotating a bootstrap password after the
database has persisted it and prevents Argo CD pruning from silently deleting
credentials.

Keycloak and monetization data use separate PostgreSQL clusters. The demo uses
one database instance and a small PVC per cluster to limit resource consumption.
A production overlay must use at least three instances, tested backup and restore,
an object-store backup target, disruption budgets, and topology-aware placement.

## Consequences

- No secret values exist in Git or rendered manifests.
- A fresh demo cluster does not require Vault or a cloud secret manager.
- Demo-generated credentials are intentionally not a production secret strategy.
- Production overlays replace generators with provider-backed `SecretStore` and
  `ExternalSecret` resources while preserving target Secret names and keys.
- Deleting and recreating a database cluster requires coordinated deletion of
  its immutable generated credential; deleting only one side can make the
  database inaccessible.
- CloudNativePG bootstrap SQL runs once. Application schema changes after the
  first release require a versioned migration tool.
