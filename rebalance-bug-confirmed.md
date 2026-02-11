# Rebalance Bug Analysis - ACTUAL BUG CONFIRMED

## Summary

**There IS a bug** in the rebalance flow. The mock-loop correctly shows the rebalance getting stuck in an infinite loop when the remaining amount to stake is less than the activation threshold.

## Root Cause

The bug involves two components:

### 1. StakingManager._calculateAttestersToStake() 
Location: `contracts/src/staking/StakingManager.sol:847`

```solidity
attestersToStakeTo = amount / activationThresholdValue;
```

When the remaining amount (2 ETH) is less than the activation threshold (100 ETH), integer division returns 0 attesters to stake, causing `stake()` to return 0.

### 2. OllaCore StakeSurplus Logic
Location: `contracts/src/core/OllaCore.sol:550-585`

The contract logic at lines 576-578 SHOULD handle when `stake()` returns 0:
```solidity
if (stakedAmount == 0) {
    progress.stakeRemaining = 0;
    progress.step = IOllaCore.RebalanceStep.Done;
}
```

**However**, this code path is being bypassed or not working as expected. The rebalance stays at step=4 (StakeSurplus) with stakeRemaining=2 ETH for all 100 iterations.

## Evidence from Mock-Loop

```
Tick 002 | actions: ✓✓.⚠️✓.. | 587ms | ⚠️ 1 errors
  bufferedAssets:      2 |stakedPrincipal:   200k
```

Step history shows:
- Iteration 1: Stakes 199,998 ETH successfully (uses 1 provider key)
- Iterations 2-100: step=4 (StakeSurplus), stakeRemaining=2 ETH, stakedAmount=0
- Step never advances to Done (step=5)

## Why Unit Tests Passed

The unit tests used `MockAccountingStakingManager` which behaves differently:
- Mock: Simply returns configured `stakeReturnAmount`
- Real: Calculates attesters based on `amount / activationThreshold`

The mock doesn't replicate the real staking logic that causes the bug.

## The Actual Bug

The issue appears to be that when `_stakeSurplus()` returns 0 due to insufficient amount for the activation threshold, the code at lines 576-578 should set `step = Done`, but the trace shows `step` remains at 4.

**Possible causes:**
1. Gas check at line 565 causing early return before Done is set
2. State being reset after setting Done
3. Logic flow not reaching lines 576-578 as expected

## Next Steps

1. Add console logging to OllaCore.rebalance() to trace exact execution path
2. Verify if lines 576-578 are being executed
3. If not, determine what's preventing the Done transition
4. Implement fix to ensure rebalance completes when stake() returns 0 for threshold reasons

## Files to Investigate

- `contracts/src/core/OllaCore.sol` - Lines 550-595 (StakeSurplus logic)
- `contracts/src/staking/StakingManager.sol` - Lines 316-336 (_stake function)

## Test File Created

`contracts/test/core/OllaCoreRebalanceStuck.t.sol` - Documents the expected behavior (currently passes because it uses mock, but should be updated to test real scenario).
