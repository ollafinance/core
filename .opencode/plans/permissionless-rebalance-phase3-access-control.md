# Phase 3: Permissionless Access Control & Cooldown

## Scope

Remove `OPERATOR_ROLE` from `rebalance()` and `updateAccounting()` on OllaCore. Remove `onlyCoreOrOperator` from `computeAttesterState()` on StakingManager. Add a cooldown mechanism that rate-limits how often new rebalance cycles can start, applied uniformly to all callers.

## Prerequisites

Phase 1 (finalizeExits extraction) and Phase 2 (pause removal) must be complete.

## Implementation Steps

### 1. Make `updateAccounting()` permissionless

File: `contracts/src/core/OllaCore.sol` (line ~839)

Remove `onlyRole(OPERATOR_ROLE)`. Keep `whenNotPaused`, `whenRebalanceDone`, `nonReentrant`:

```solidity
function updateAccounting()
    external override
    whenNotPaused
    whenRebalanceDone
    nonReentrant
{
    _updateAccountingInternal();
}
```

### 2. Make `computeAttesterState()` permissionless

File: `contracts/src/staking/StakingManager.sol` (line ~247)

Remove `onlyCoreOrOperator`. Keep `nonReentrant`:

```solidity
function computeAttesterState() external nonReentrant returns (...) {
    // ... existing logic unchanged ...
}
```

### 3. Add cooldown state to OllaCore

File: `contracts/src/core/OllaCore.sol`

```solidity
/// @notice Minimum seconds between new rebalance cycles. 0 = disabled (rebalance blocked).
uint256 public rebalanceCooldown;

/// @notice Maximum allowed cooldown value.
uint256 internal constant MAX_REBALANCE_COOLDOWN = 24 hours;
```

### 4. Add cooldown gate to `rebalance()`

File: `contracts/src/core/OllaCore.sol` (line ~609)

Remove `onlyRole(OPERATOR_ROLE)`. Add cooldown check for new cycle starts only:

```solidity
function rebalance()
    external override
    whenNotPaused
    nonReentrant
    returns (...)
{
    // ... existing liveness check ...

    if (progress.step == IOllaCore.RebalanceStep.Done) {
        // Cooldown gate: all callers must wait rebalanceCooldown seconds
        // after the last accounting update before starting a new cycle.
        {
            uint256 cooldown_ = rebalanceCooldown;
            if (cooldown_ == 0) {
                revert OllaCore__RebalanceCooldownActive(0, 0);
            }
            uint256 elapsed = block.timestamp - _latestReport.timestamp;
            if (elapsed < cooldown_) {
                revert OllaCore__RebalanceCooldownActive(elapsed, cooldown_);
            }
        }

        // EXISTING: idle buffer guard (unchanged)
        // ...
    }
    // Continuations of in-progress cycles always allowed (no cooldown check)
}
```

### 5. Add `setRebalanceCooldown()` governance setter

File: `contracts/src/core/OllaCore.sol`

```solidity
function setRebalanceCooldown(uint256 cooldown_)
    external override
    onlyRole(DEFAULT_ADMIN_ROLE)
    whenNotPaused
    whenRebalanceDone
{
    if (cooldown_ > MAX_REBALANCE_COOLDOWN) {
        revert OllaCore__InvalidParameter();
    }
    uint256 old = rebalanceCooldown;
    rebalanceCooldown = cooldown_;
    emit RebalanceCooldownUpdated(old, cooldown_);
}
```

### 6. Update IOllaCore interface

File: `contracts/src/core/interfaces/IOllaCore.sol`

```solidity
error OllaCore__RebalanceCooldownActive(uint256 elapsed, uint256 required);
event RebalanceCooldownUpdated(uint256 indexed oldCooldown, uint256 indexed newCooldown);
function setRebalanceCooldown(uint256 cooldown_) external;
function rebalanceCooldown() external view returns (uint256);
```

### 7. Initialize cooldown in `initialize()`

File: `contracts/src/core/OllaCore.sol`

Set a default cooldown in the initializer (e.g. `rebalanceCooldown = 1 hours`), or accept it as a constructor/initializer parameter.

## Test Cases

1. Anyone can start rebalance when cooldown elapsed and work available
2. Rebalance reverts with `OllaCore__RebalanceCooldownActive` when cooldown not elapsed
3. Rebalance reverts when cooldown is 0 (disabled / protocol defense)
4. Anyone can continue an in-progress cycle (no cooldown check on continuations)
5. Cooldown resets after cycle completion (accounting timestamp updates via `_updateAccountingInternal`)
6. Repeated cycles blocked by cooldown between each
7. Idle buffer guard still works for all callers
8. `setRebalanceCooldown()` only callable by DEFAULT_ADMIN_ROLE
9. `setRebalanceCooldown()` reverts for values > MAX_REBALANCE_COOLDOWN
10. `setRebalanceCooldown()` reverts during in-progress rebalance
11. Anyone can call `updateAccounting()` (no OPERATOR_ROLE needed)
12. Anyone can call `computeAttesterState()` (no onlyCoreOrOperator needed)

## Acceptance Criteria

- [x] `rebalance()` has no `onlyRole(OPERATOR_ROLE)`
- [x] `updateAccounting()` has no `onlyRole(OPERATOR_ROLE)`
- [x] `computeAttesterState()` has no `onlyCoreOrOperator`
- [x] Cooldown gate prevents starting new cycles too frequently
- [x] Cooldown = 0 disables rebalance (defense mechanism)
- [x] Continuations bypass cooldown
- [x] `setRebalanceCooldown()` validates against MAX_REBALANCE_COOLDOWN

## Verification

```bash
forge build
forge test --match-contract OllaCorePermissionlessRebalance -vvv
forge test --match-contract OllaCoreRebalance -vvv
forge test --match-contract StakingManager -vvv
```
