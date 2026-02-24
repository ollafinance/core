# Phase 1: Extract `finalizeExits()` & Fix Double-Counting

## Scope

Extract the gas-heavy `rollup.finalizeWithdraw()` loop out of rebalance into a standalone permissionless function on StakingManager. Fix the `stakedPrincipal` double-counting bug in `_pullUnstakedFunds()`. Protect against donation griefs by tracking `_pendingClaimAmount` separately.

## Prerequisites

None — this is the first phase.

## Implementation Steps

### 1. Add `_pendingClaimAmount` state to StakingManager

File: `contracts/src/staking/StakingManager.sol`

Add a private state variable to track finalized-but-unclaimed exit amounts:

```solidity
uint256 private _pendingClaimAmount; // tracks finalized but unclaimed exit amounts
```

### 2. Add `finalizeExits()` to StakingManager

File: `contracts/src/staking/StakingManager.sol`

New permissionless function that finalizes exitable attesters on the rollup:

```solidity
/// @notice Finalizes exitable attesters on the rollup. Permissionless.
/// Tokens move from rollup to StakingManager. Attesters removed from registry.
function finalizeExits() external nonReentrant returns (uint256 finalized) {
    (, IAztecRollup rollup) = _getRollup();
    finalized = _finalizeExits(rollup); // existing bounded iteration logic
    _pendingClaimAmount += finalized;
    return finalized;
}
```

### 3. Modify `getUnstakedFunds()` in StakingManager

File: `contracts/src/staking/StakingManager.sol`

Replace the current implementation (which calls `_claimUnstakedFunds()` -> `_finalizeUnstakes()` + `_finalizeClaim()`) with a simple sweep that returns `exitAmount` separately:

```solidity
/// @notice Sweeps all funds from StakingManager to core. Called during rebalance.
/// Returns the exit amount separately for correct accounting.
function getUnstakedFunds() external onlyCore nonReentrant
    returns (uint256 received, uint256 exitAmount, bool hasRemainingExits)
{
    exitAmount = _pendingClaimAmount;
    _pendingClaimAmount = 0;

    uint256 balance = stakingAsset.balanceOf(address(this));
    if (balance > 0) {
        stakingAsset.safeTransfer(core, balance);
    }
    received = balance;
    hasRemainingExits = _exitingCount > 0;
}
```

### 4. Update IStakingManager interface

File: `contracts/src/staking/interfaces/IStakingManager.sol`

Add `finalizeExits()` and update `getUnstakedFunds()` return signature:

```solidity
function finalizeExits() external returns (uint256 finalized);
function getUnstakedFunds() external returns (uint256 received, uint256 exitAmount, bool hasRemainingExits);
```

### 5. Update `_pullUnstakedFunds()` in OllaCore

File: `contracts/src/core/OllaCore.sol` (line ~1165)

Handle the new return signature and fix the double-counting:

```solidity
function _pullUnstakedFunds() internal returns (uint256 receivedAmount, bool hasRemainingExits) {
    uint256 balanceBefore = _modules.asset.balanceOf(address(this));

    uint256 exitAmount;
    (receivedAmount, exitAmount, hasRemainingExits) = _modules.stakingManager.getUnstakedFunds();

    uint256 balanceAfter = _modules.asset.balanceOf(address(this));
    uint256 actualReceived = balanceAfter - balanceBefore;

    if (receivedAmount != 0 && receivedAmount != actualReceived) {
        revert OllaCore__UnstakedFundsMismatch(receivedAmount, actualReceived);
    }

    if (actualReceived > 0) {
        _accountingState.bufferedAssets += actualReceived;
    }
    // Fix double-counting: move exit amount from staked to buffer bucket
    if (exitAmount > 0) {
        _accountingState.stakedPrincipal -= exitAmount;
    }

    return (actualReceived, hasRemainingExits);
}
```

## Key Properties

- `exitAmount` only reflects real finalized exits (from `_pendingClaimAmount`), not donations
- Donations increase `bufferedAssets` without incorrectly reducing `stakedPrincipal`
- `totalAssets()` remains accurate: `buffer += received` and `staked -= exitAmount` means net change only from donations
- The existing `_finalizeExits()` bounded iteration logic is reused unchanged

## Test Cases

1. `finalizeExits()` correctly finalizes exiting attesters and tracks `_pendingClaimAmount`
2. Multiple `finalizeExits()` calls accumulate `_pendingClaimAmount` correctly
3. `getUnstakedFunds()` returns correct `exitAmount` and resets `_pendingClaimAmount` to 0
4. Donation to StakingManager: swept to core as `received` but NOT reflected in `exitAmount`
5. After pull: `totalAssets()` = previous `totalAssets()` + donation amount (no double-counting)
6. No exitable attesters: `finalizeExits()` returns 0, `_pendingClaimAmount` unchanged

## Acceptance Criteria

- [x] `finalizeExits()` is callable by anyone
- [x] `getUnstakedFunds()` returns `(received, exitAmount, hasRemainingExits)`
- [x] `_pullUnstakedFunds()` decreases `stakedPrincipal` by `exitAmount`
- [x] Donation griefs do not corrupt `stakedPrincipal`
- [x] `totalAssets()` is accurate immediately after PullUnstaked step

## Verification

```bash
forge build
forge test --match-contract StakingManagerFinalizeExits -vvv
forge test --match-contract OllaCoreRebalance -vvv
```
