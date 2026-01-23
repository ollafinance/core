# Phase 0: Baseline + Scope Lock

## Goals

- Make explicit the trust boundaries for StakingManager.
- Write down invariants and external-call surfaces.
- Identify the minimal changes needed for upgradeability and safety.

## External Calls / Surfaces

StakingManager makes external calls to:

- `ROLLUP_REGISTRY.getCanonicalRollup()`
- `IAztecRollup.deposit(...)`
- `IAztecRollup.initiateWithdraw(...)`
- `IAztecRollup.finalizeWithdraw(...)`
- `IAztecRollup.claimSequencerRewards(address)`
- `IAztecRollup.getAttesterView(address)`
- `REWARDS_VAULT.postReceiveFundsHook(uint256)`

## Trust Assumptions (to be enforced in tests)

- The canonical rollup returned by `ROLLUP_REGISTRY` is governance-controlled and treated as trusted for correctness.
- `REWARDS_VAULT` is part of the protocol system, but still must not be able to reenter state-changing StakingManager paths.

## Core Invariants

- Attester state exclusivity:
  - No attester is simultaneously in `_activatedAttesters` and `_pendingUnstakeRequests`.
  - `_isActivatedAttester[attester]` and `_attesterIndex[attester]` are consistent with `_activatedAttesters`.
  - `_isUnstakePending[attester]` is consistent with `_pendingUnstakeRequests`.
- Accounting expectations:
  - `stake(amount)` only transfers `N * activationThreshold` from `CORE`.
  - After `stake`, allowance to the rollup is reset to 0.
- Reward harvesting:
  - `harvestRewards()` claims rollup rewards to the vault and calls the vault hook with the same amount.

## Tests / Gaps Identified

- StakingManager is currently constructor-based and non-upgradeable.
- Tests assume direct deployment. These must change to proxy deployment when Phase 1 lands.
- Invariants that assume vault token balance changes must match the actual Aztec reward transfer semantics.

## Deliverables

- This document (baseline).
- A concrete implementation plan in Phase 1+ docs.
