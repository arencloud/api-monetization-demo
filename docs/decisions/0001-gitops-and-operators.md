# ADR 0001: GitOps and operator ownership

- Status: Accepted
- Date: 2026-08-10

## Context

The demonstration must be repeatable and must showcase supported Red Hat
deployment mechanisms. Several platform products install CRDs and manage
stateful or cluster-scoped operands. Applying all resources in one pass can race
OLM installation and obscures component ownership.

## Decision

OpenShift GitOps owns all steady-state resources. A minimal, idempotent bootstrap
installs the GitOps Operator and creates one root application. Child applications
separate namespaces, OLM subscriptions, and operands using sync waves.

When an appropriate Operator exists, it owns that service. The repository does
not duplicate dependencies installed by another supported product Operator. In
particular, RHCL owns its Authorino, Limitador, and DNS operator dependencies.

## Consequences

- Cluster state can be reconstructed and audited from Git.
- CRD and operand reconciliation are isolated and retryable.
- Product compatibility is reviewed at the profile level.
- Bootstrap remains a necessary but deliberately small exception to steady-state
  GitOps.
- Database and secret-management operator selection must be recorded in later
  ADRs before those services are added.

