# Fixes for Rebalance Infinite Restart Bug

## Bug Summary

When `rebalance()` is called after a completed cycle (`step=Done`, `_rebalancePaused=false`), it unconditionally starts a new rebalance cycle. If the buffer contains a small unstakeable remainder (e.g., 2 ETH < 32 ETH minimum), the new cycle runs through all 6 steps, discovers it can't stake the remainder, completes to Done, and unpauses -- only for the next call to repeat the same pointless cycle forever.

**Location**: `contracts/src/core/OllaCore.sol:458-465`

```solidity
if (progress.step == IOllaCore.RebalanceStep.Done) {
    if (!_rebalancePaused) {
        _rebalancePaused = true;               // starts new cycle
        _rebalancePauseReason = ...;
        (uint256 requiredBuffer,) = _computeRequiredBuffer();
        _rebalanceRequiredBufferSnapshot = requiredBuffer;
    }
    _syncBufferedWithBalance();
    progress.step = IOllaCore.RebalanceStep.Harvest;  // always advances
    ...
}
```

The block always transitions from `Done` to `Harvest`, even when there is nothing productive to do.

---

## Fix Options

### Fix 1: Early exit when no work is needed (Recommended)

Before starting a new cycle, check if there's actually work to do. If the buffer is at or below the required level (or the surplus is unstakeable), skip the cycle entirely.

```solidity
if (progress.step == IOllaCore.RebalanceStep.Done) {
    if (!_rebalancePaused) {
        // Check if there is actually work to do before starting a new cycle
        (uint256 requiredBuffer,) = _computeRequiredBuffer();
        uint256 surplus = _computeStakeRemaining(requiredBuffer);
        uint256 deficit = _computeUnstakeRemaining(requiredBuffer);
        uint256 pending = _modules.withdrawalQueue.totalPendingAssets();

        // No surplus to stake, no deficit to unstake, no pending withdrawals
        if (surplus == 0 && deficit == 0 && pending == 0) {
            return (0, 0, 0, _accountingState.bufferedAssets);
        }

        _rebalancePaused = true;
        _rebalancePauseReason = uint8(IOllaCore.RebalancePauseReason.RebalanceStart);
        emit RebalancePauseUpdated(true, IOllaCore.RebalancePauseReason.RebalanceStart);
        _rebalanceRequiredBufferSnapshot = requiredBuffer;
    }
    _syncBufferedWithBalance();
    progress.step = IOllaCore.RebalanceStep.Harvest;
    ...
}
```

**Pros**: Clean, prevents the cycle from starting at all. No wasted gas, no transient pause.  
**Cons**: Doesn't handle the case where surplus > 0 but is too small to stake (e.g., 2 ETH < 32 ETH minimum). Would still start a cycle for 2 ETH surplus.

### Fix 2: Early exit with minimum stake threshold

Same as Fix 1 but also checks if the surplus is below a meaningful staking threshold.

```solidity
if (surplus == 0 && deficit == 0 && pending == 0) {
    return (0, 0, 0, _accountingState.bufferedAssets);
}

// Also skip if the only work is staking a trivially small surplus
if (deficit == 0 && pending == 0 && surplus > 0) {
    // Try a dry-run: if stakingManager can't stake this amount, don't bother
    // This requires stakingManager to expose a canStake() or minimumStake() view
}
```

**Pros**: More precise, avoids cycles even for small surpluses.  
**Cons**: Requires the staking manager to expose a view function for the minimum stakeable amount. More coupling.

### Fix 3: Track "last completed with no progress" state

Add a flag or counter that tracks whether the last completed cycle made any productive work (staked > 0 or finalized > 0). If the last cycle was a no-op, don't start a new one.

```solidity
if (progress.step == IOllaCore.RebalanceStep.Done) {
    if (!_rebalancePaused) {
        // If last cycle was unproductive, don't start a new one
        if (_lastRebalanceWasNoOp) {
            return (0, 0, 0, _accountingState.bufferedAssets);
        }
        _rebalancePaused = true;
        ...
    }
    ...
}

// At the end, after setting Done:
if (progress.step == IOllaCore.RebalanceStep.Done) {
    _lastRebalanceWasNoOp = (stakedAmount == 0 && finalizedAmount == 0);
}
```

**Pros**: Self-correcting -- if conditions change (new deposits, new keys), the flag resets naturally.  
**Cons**: Adds storage variable. The flag needs to be cleared on deposits/withdrawals to ensure rebalance restarts when conditions change.

---

## Recommended Approach

**Fix 1** is the simplest and most correct. It checks at the top of the Done block whether there's actually work to do, and returns early if not. The small unstakeable remainder (2 ETH) will have `_computeStakeRemaining` return 2 ETH (surplus > 0), which means the cycle still starts. 

To fully solve the problem, combine with a check in the StakeSurplus step: if `_stakeSurplus` returns 0 on the first attempt of a new cycle, set the surplus as "accepted" buffer and complete without cycling.

Alternatively, the simplest complete fix: in the `Done` block, after computing surplus, also try staking it. If staking returns 0, just return early without starting a cycle:

```solidity
if (progress.step == IOllaCore.RebalanceStep.Done) {
    if (!_rebalancePaused) {
        (uint256 requiredBuffer,) = _computeRequiredBuffer();
        uint256 surplus = _computeStakeRemaining(requiredBuffer);
        
        // If there's no work to do, or the surplus can't actually be staked, skip
        if (surplus == 0 && _computeUnstakeRemaining(requiredBuffer) == 0) {
            return (0, 0, 0, _accountingState.bufferedAssets);
        }
        
        _rebalancePaused = true;
        ...
    }
    ...
}
```

This still has the issue of starting a cycle for 2 ETH surplus. The truly complete fix needs to happen in the StakeSurplus -> Done transition: when `stake()` returns 0, don't just set Done -- also zero out the surplus in accounting so the next call doesn't see it as work.

---

## Test Commands

```bash
# Run the failing tests that prove the bug
yarn test:rebalance-infinite-restart

# Run the original (passing) tests 
yarn test:rebalance-stuck
```

## Files

- **Bug test**: `contracts/test/core/OllaCoreRebalanceInfiniteRestart.t.sol`
- **Bug location**: `contracts/src/core/OllaCore.sol:458-465`
- **Bug analysis**: `rebalance-bug-confirmed.md`
