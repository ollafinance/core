# Phase 2: Access Control Hardening

## Goal

Make role and admin boundaries explicit and testable.

## Work Items

- Decide source of truth for provider admin:
  - Keep `_provider.admin` + `STAKING_PROVIDER_ADMIN_ROLE` in sync, or remove redundancy.
- Decide whether `CORE` is immutable-in-practice or rotatable:
  - If rotatable: add admin-only `setCore(address)` and migrate role.
- Lock down upgrade governance:
  - Ensure `_authorizeUpgrade` requires the configured governance address.

## Tests

- Negative tests for all role-gated entrypoints.
- Admin rotation tests (if supported).
