# Phase 4: Storage Layout Lock

## Goal

Ensure the proxy storage layout is upgrade-safe.

## Work Items

- Confirm all storage variables are ordered and documented.
- Add/size `__gap` for future additions.
- Add an upgrade regression test using a V2 implementation with a new variable.
