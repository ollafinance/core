# M-08 Approaches: Governance Address Divergence

## Problem
OllaCore governance is mutable, but StakingManager and StakingProviderRegistry have their own governance addresses set once at initialization. After a governance transfer, upgrade authorization can diverge across contracts.

## Constraints
- No changes to OllaCore.sol in this branch.
- StakingManager and StakingProviderRegistry are UUPS proxies.
- Both contracts already check `msg.sender == governance` in `_authorizeUpgrade`.

## Goals
- Keep governance consistent across contracts.
- Preserve upgrade authorization safety.
- Minimize operational risk during governance migration.

## Approach A: Add setGovernance() to StakingManager and StakingProviderRegistry
Provide a direct setter to update local governance on both contracts.

**Design**
- Add `setGovernance(address newGovernance)` with `onlyRole(DEFAULT_ADMIN_ROLE)`.
- Update storage `governance` and emit `GovernanceUpdated(old, new)`.
- Consider adding two-step pattern here too if OllaCore adopts it.

**Pros**
- Direct and explicit; easy to audit.
- No dependency on OllaCore for propagation.

**Cons**
- Requires two additional admin calls during migration.
- If OllaCore adds a two-step flow, these can drift unless updated together.

## Approach B: Propagate from OllaCore
Have OllaCore push the governance update to the other contracts.

**Design**
- Modify OllaCore governance transfer to call `setGovernance()` on SM and SPR.
- Ensure OllaCore has the necessary admin role or dedicated function permission.

**Pros**
- Single source of truth; fewer manual steps.

**Cons**
- Requires changes in OllaCore.sol (not allowed in this branch).
- Cross-contract calls add upgrade coupling and potential failure points.

## Approach C: Centralized Governance Registry
Store governance in a shared registry contract queried by all modules.

**Design**
- New contract `GovernanceRegistry` with `governance()` and `setGovernance()`.
- SM and SPR read registry when authorizing upgrades.
- OllaCore updates registry on governance transfer.

**Pros**
- Single authoritative governance value.
- Easier to extend with additional modules.

**Cons**
- Adds an extra contract and dependency.
- Requires coordinated upgrades across modules.

## Approach D: Role-Only Upgrade Authorization
Remove per-contract governance storage and rely purely on roles.

**Design**
- `_authorizeUpgrade` checks only `onlyRole(DEFAULT_ADMIN_ROLE)`.
- Governance role is managed via AccessControl across all contracts.

**Pros**
- Simplifies storage and reduces divergence risk.
- Avoids explicit governance variable updates.

**Cons**
- Weakens the second check currently used to bind upgrades to a single governance address.
- Less strict than existing safety posture.

## Migration Notes
- If using Approach A, update SM and SPR in the same timelock batch as OllaCore governance transfer.
- Emit events and verify governance values after execution.

## Suggested Implementation Path
Approach A is the lowest-risk, minimal-change fix. Combine it with a timelock batched execution to ensure all contracts update together. If you later centralize governance (Approach C), keep Approach A as a compatibility bridge during migration.
