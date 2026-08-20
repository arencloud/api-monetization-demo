# ADR 0009: Self-service consumers and reviewed API owners

## Status

Accepted.

## Context

Developer Hub needs a repeatable first-user experience on a fresh cluster.
Consumers must be able to register without a cluster administrator, while API
owners receive privileged catalog, scaffolder, Dev Spaces, and publication
permissions. Allowing a user to choose the owner group on a public form would
bypass platform governance.

## Decision

Use the Red Hat build of Keycloak registration page as the single account
signup surface. New identities enter `api-consumers` through the realm default
group. Group-to-role mapping grants the control-plane developer role, and the
RHDH Keycloak provider synchronizes the user and group.

Expose owner onboarding in the RHDH **Subscriptions & Access** extension. Store
requests and review decisions in the monetization PostgreSQL database. Only an
RHDH API administrator may approve or reject a request. Approval adds the
Keycloak `api-owners` group and removes `api-consumers`; a fresh login then
delivers the owner role and owner-specific catalog policy.

Use a separate confidential Keycloak service client for approval. Grant it
only `manage-users`, `query-users`, and `query-groups`; keep RHDH's organization
provider client read-only. Generate both secrets with External Secrets and do
not expose them to the browser.

Build a custom RHBK image from the exact GitOps revision for the login theme.
Extend the supported `keycloak.v2` theme and use PatternFly/Red Hat visual
tokens. Use RHDH's supported `app.branding` settings for the authenticated UI.

## Consequences

- New consumers can register, subscribe, and use APIs without manual Keycloak
  role assignment.
- Owner privileges require an auditable administrative decision.
- Promotion requires sign-out/sign-in and up to the ten-second RHDH
  synchronization interval before the new catalog capabilities appear.
- The secure immutable-user-ID resolver remains mandatory. A just-registered
  user might need to select sign in once more if its automatic callback wins
  the race with the first catalog refresh; no unsafe resolver bypass is used.
- The demo does not require SMTP. Its custom RHBK listener marks successful
  local form registrations as email verified so the portable onboarding path
  is deterministic. This trusts the submitted address; a production overlay
  must remove the listener and add SMTP-backed email verification plus the
  enterprise identity policy.
- Identity authority remains Keycloak, commercial/workflow authority remains
  PostgreSQL, and RHDH remains the unified presentation and permission layer.
