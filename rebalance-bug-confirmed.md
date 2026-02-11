# Rebalance Bug - CONFIRMED AND PROVEN

## Summary

There is a bug in `OllaCore.rebalance()` that causes an **infinite restart loop** when there is an unstakeable remainder in the buffer (e.g., 2 ETH when the staking minimum is 32 ETH).

## Root Cause

When `rebalance()` completes a cycle (reaches `step=Done`) and clears the pause flag, the **next** call to `rebalance()` starts a brand new cycle unconditionally. The new cycle recalculates `stakeRemaining = bufferedAssets - requiredBuffer`, rediscovers the same small remainder, tries to stake it, gets 0 back from the staking manager, sets `step=Done`, clears the pause -- and the pattern repeats forever.

### Detailed Flow

**Setup**: 200k ETH deposited, `targetBufferedAssets=0`, staking manager stakes 199,998 ETH leaving 2 ETH buffered.

**Call 1** (`step=StakeSurplus, stakeRemaining=2 ETH` from previous save):
1. Enters StakeSurplus block, calls `_stakeSurplus(2 ETH)` -> returns 0
2. `stakedAmount == 0 && stakeRemaining != 0` -> sets `step=Done, stakeRemaining=0`
3. `_rebalanceCompletionSatisfied()` returns true -> sets `_rebalancePaused = false`

**Call 2** (`step=Done`):
1. Enters `if (progress.step == Done)` at line 458
2. `_rebalancePaused == false` -> sets `_rebalancePaused = true` (NEW CYCLE!)
3. Sets `step=Harvest`, falls through ALL steps: Harvest -> PullUnstaked -> FinalizeWithdrawals -> InitiateUnstake -> StakeSurplus
4. Recalculates `stakeRemaining = bufferedAssets - requiredBuffer = 2 ETH - 0 = 2 ETH`
5. Calls `_stakeSurplus(2 ETH)` -> returns 0
6. Sets `step=Done`, clears pause
7. Returns -- but calling rebalance AGAIN repeats the exact same cycle

**Every subsequent call repeats Call 2 exactly.**

### Location

`contracts/src/core/OllaCore.sol` lines 458-465 -- the `if (progress.step == Done)` block unconditionally starts a new cycle whenever it's called with `step=Done`.

## Impact

1. **Mock-loop infinite loop**: The off-chain operator loop calls `rebalance()` repeatedly. Each call does a full cycle (Done -> Harvest -> ... -> StakeSurplus -> Done), but from the loop's perspective, it reads `rebalanceProgress()` which shows the intermediate saved state before the final `Done` (or sees `Done` but calls again). The loop hits the 100-iteration safety limit.
2. **Transient pause cycling**: Every call sets `_rebalancePaused=true` then back to `false`. Any concurrent operation protected by `whenNotRebalancePaused` (deposits, redemptions, `updateAccounting`, etc.) can be blocked during this window.
3. **Wasted gas**: Each unnecessary cycle runs through all 6 rebalance steps for no productive work.

## Proof

Two failing Foundry tests in `contracts/test/core/OllaCoreRebalanceInfiniteRestart.t.sol`:

### `test_RebalanceDoesNotInfinitelyRestart`
After 3 calls complete the initial rebalance, a 4th call emits a `Rebalanced` event, proving a full unnecessary cycle ran. **Expected 0 events, got 1.**

### `test_RebalanceRepeatedPauseCycling`
Over 5 rebalance calls after the initial cycle completes, 10 `RebalancePauseUpdated` events are emitted (2 per call: pause=true at start, pause=false at end). **Expected 0 events, got 10.**

### Run the tests

```bash
yarn test:rebalance-infinite-restart
```

Both tests FAIL, proving the bug exists.

## Why Earlier Unit Tests Missed This

The earlier tests in `OllaCoreRebalanceStuck.t.sol` verified that a single rebalance call correctly transitions from StakeSurplus to Done when `stake()` returns 0. That logic IS correct. The bug is not in the StakeSurplus-to-Done transition -- it's that **calling rebalance again after Done unconditionally starts a new cycle**, creating the infinite loop.

## Files

- **Bug test**: `contracts/test/core/OllaCoreRebalanceInfiniteRestart.t.sol`
- **Bug location**: `contracts/src/core/OllaCore.sol:458-465`
- **Fix proposals**: See `fixes-rebalance-bug.md`
