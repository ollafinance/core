# Permissionless Rebalance & Accounting Implementation Plan

This plan covers making `rebalance()`, `updateAccounting()`, and `computeAttesterState()` permissionless, extracting `finalizeExits()`, fixing the PullUnstaked double-counting bug, and removing the rebalance pause.

## Overview

Currently `rebalance()`, `updateAccounting()`, and `computeAttesterState()` are gated behind `OPERATOR_ROLE`. This creates a single point of failure: if the operator goes down, the protocol stalls. Making these functions permissionless improves liveness and decentralisation.

The main challenge is that `rebalance()` **pauses the entire protocol** during execution. Analysis shows this pause exists to prevent economic exploitation from stale/inconsistent `totalAssets()` during rebalance. However, the MEV window between accounting updates dwarfs the rebalance cycle duration, so the pause provides minimal incremental protection. By fixing the root cause (the `stakedPrincipal` double-counting in PullUnstaked), we can **remove the pause entirely**.

### Key Design Decisions

1. **Remove the rebalance pause** — MEV from stale rates exists 99% of the time between accounting updates anyway; the pause only closes the last ~1% of the window. Real protection comes from frequent accounting updates and SafetyModule circuit breakers.
2. **Fix PullUnstaked double-counting** — When unstaked funds are pulled, decrease `stakedPrincipal` by the exit amount (not donation amount) to keep `totalAssets()` accurate during rebalance.
3. **Extract `finalizeExits()` from rebalance** — The rollup `finalizeWithdraw()` calls (gas-heavy, multi-pass) become a separate permissionless function on StakingManager. Rebalance PullUnstaked only sweeps already-available funds.
4. **Cooldown for new rebalance cycles** — Rate-limits how often new cycles can start. Applied uniformly to all callers.
5. **Make state machine resilient** — Always recompute `stakeRemaining`/`unstakeRemaining` from current state to handle concurrent user operations.

## Architecture Context

```
                 ┌──────────────┐
   anyone ──────>│ finalizeExits│  (new, permissionless on StakingManager)
                 │  rollup.finalizeWithdraw() per attester
                 │  tokens: rollup -> StakingManager
                 │  tracks _pendingClaimAmount
                 └──────────────┘

   anyone ──────>│  rebalance() │  (permissionless + cooldown on OllaCore)
                 │              │
                 │  Step: PullUnstaked
                 │    getUnstakedFunds() -> sweeps StakingManager balance to Core
                 │    returns (received, exitAmount, hasRemainingExits)
                 │    Core: bufferedAssets += received, stakedPrincipal -= exitAmount
                 │              │
                 │  Step: FinalizeWithdrawals / InitiateUnstake / StakeSurplus / etc.
                 │    (unchanged logic, but stakeRemaining/unstakeRemaining recomputed)
                 │              │
                 │  On completion: _updateAccountingInternal()
                 └──────────────┘

   anyone ──────>│ updateAccounting() │  (permissionless, whenRebalanceDone)

   anyone ──────>│ computeAttesterState() │  (permissionless on StakingManager)
```

## Overview Table

| Function | Current Gate | Change | Risk |
|----------|-------------|--------|------|
| `updateAccounting()` | `OPERATOR_ROLE` | Remove role check | Low |
| `computeAttesterState()` | `onlyCoreOrOperator` | Remove access check | Low |
| `rebalance()` | `OPERATOR_ROLE` + pause | Remove role + remove pause + add cooldown | Medium |
| `finalizeExits()` | N/A (new) | New permissionless function on StakingManager | Low |

## Phase Summary

| Phase | Scope |
|-------|-------|
| [Phase 1](./permissionless-rebalance-phase1-finalize-exits.md) | Extract `finalizeExits()`, fix PullUnstaked accounting |
| [Phase 2](./permissionless-rebalance-phase2-remove-pause.md) | Remove rebalance pause, make state machine resilient |
| [Phase 3](./permissionless-rebalance-phase3-access-control.md) | Remove OPERATOR_ROLE, add cooldown |
| [Phase 4](./permissionless-rebalance-phase4-tests.md) | Test coverage |

## Files to Create/Modify

| File | Description |
|------|-------------|
| `contracts/src/staking/StakingManager.sol` | Add `_pendingClaimAmount`, add `finalizeExits()`, modify `getUnstakedFunds()` return, remove `onlyCoreOrOperator` from `computeAttesterState()` |
| `contracts/src/staking/interfaces/IStakingManager.sol` | Add `finalizeExits()`, update `getUnstakedFunds()` signature |
| `contracts/src/core/OllaCore.sol` | Remove pause mechanism; add `whenRebalanceDone`; fix `_pullUnstakedFunds` accounting; recompute remaining amounts; fix `_stakeSurplus` catch; add cooldown; remove OPERATOR_ROLE; simplify completion logic |
| `contracts/src/core/interfaces/IOllaCore.sol` | Remove pause types/events; add cooldown error/event/setter; rename `forceRebalanceUnpause` -> `forceRebalanceReset` |
| `contracts/test/core/olla-core/OllaCorePermissionlessRebalance.t.sol` | New: cooldown, concurrent ops, state machine resilience |
| `contracts/test/staking/StakingManagerFinalizeExits.t.sol` | New: finalizeExits, donation handling, accounting correctness |
| `contracts/test/core/olla-core/OllaCoreRebalance.t.sol` | Update for permissionless + cooldown |
| `contracts/test/core/olla-core/OllaCoreRebalancePause.t.sol` | Remove/refactor (pause removed) |
| `contracts/test/core/olla-core/OllaCoreRebalanceIdleGuard.t.sol` | Update for cooldown |

## Verification

```bash
# Build
forge build

# Run all tests
forge test -vvv

# New permissionless tests
forge test --match-contract OllaCorePermissionlessRebalance -vvv
forge test --match-contract StakingManagerFinalizeExits -vvv

# Regression on existing rebalance tests
forge test --match-contract OllaCoreRebalance -vvv
forge test --match-contract OllaCoreRebalanceIdleGuard -vvv

# Staking manager tests
forge test --match-path test/staking/ -vvv

# Integration tests
forge test --match-path test/integration/ -vvv
```
