# Phase 4: Tests

## Scope

Comprehensive test coverage for all changes: new `finalizeExits()` function, removed pause, permissionless access, cooldown mechanism, state machine resilience under concurrent operations.

## Prerequisites

Phases 1-3 must be complete.

## New Test Files

### `contracts/test/core/olla-core/OllaCorePermissionlessRebalance.t.sol`

1. Anyone can start rebalance when cooldown elapsed and work available
2. Rebalance reverts when cooldown not elapsed
3. Rebalance reverts when cooldown is 0 (disabled)
4. Anyone can continue in-progress cycle (no cooldown)
5. Cooldown resets after cycle completion (accounting timestamp updates)
6. Repeated cycles blocked by cooldown between each
7. Idle buffer guard works for all callers
8. `setRebalanceCooldown()` validation and access control
9. User operations (`deposit`/`redeem`/`requestRedeem`) work during in-progress rebalance
10. Admin operations blocked during in-progress rebalance (`whenRebalanceDone`)
11. Concurrent deposit between rebalance calls: `stakeRemaining` recomputed correctly
12. Concurrent instant redemption between rebalance calls: `stakeRemaining` reduced correctly
13. `_stakeSurplus` gracefully handles insufficient buffer (returns 0, advances state machine)

### `contracts/test/staking/StakingManagerFinalizeExits.t.sol`

1. Anyone can call `finalizeExits()`
2. `finalizeExits()` correctly tracks `_pendingClaimAmount`
3. Multiple `finalizeExits()` calls accumulate correctly
4. `getUnstakedFunds()` returns correct `exitAmount` and resets `_pendingClaimAmount`
5. Donation to StakingManager: swept to core but not subtracted from `stakedPrincipal`
6. No exitable attesters: `finalizeExits()` returns 0

## Updates to Existing Tests

### `contracts/test/core/olla-core/OllaCoreRebalance.t.sol`

- Update all tests that use `vm.prank(operator)` to use non-privileged addresses
- Set cooldown before tests that start new cycles
- Remove pause assertions (e.g. `assertEq(core.rebalancePaused(), true)`)
- Update `getUnstakedFunds()` mock returns to match new `(received, exitAmount, hasRemainingExits)` signature

### `contracts/test/core/olla-core/OllaCoreRebalancePause.t.sol`

- Remove or refactor entirely — pause no longer exists
- Migrate any relevant tests (e.g. `forceRebalanceUnpause` -> `forceRebalanceReset`) to `OllaCorePermissionlessRebalance.t.sol`

### `contracts/test/core/olla-core/OllaCoreRebalanceIdleGuard.t.sol`

- Update for cooldown gate (tests must set `rebalanceCooldown` and warp past it)
- Verify idle guard still works correctly under permissionless access

### StakingManager tests

- Add permissionless `computeAttesterState()` tests (anyone can call, results are correct)
- Update `getUnstakedFunds()` tests for new return signature

### Accounting tests

- Add permissionless `updateAccounting()` tests (anyone can call when rebalance is Done)
- Verify `updateAccounting()` reverts during in-progress rebalance

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
