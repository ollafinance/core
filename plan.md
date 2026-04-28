NEVER build the entire project
NEVER run the entire test-suite

for above points, always refer to the user/operator to run these commands

# Controlled Rollup Transition Plan

## Goal

Implement a controlled rollup transition model in `StakingManager`: keep using a stored active rollup for rewards, block normal rollup-dependent operations during canonical mismatch, and expose a permissionless transition function that drains old rewards before switching.

## Design

Add new state to `contracts/src/staking/StakingManager.sol`:

```solidity
address public activeRollup;
```

Initialize it from `rollupRegistry.getCanonicalRollup()` during `initialize()`.

Reduce the storage gap from `48` to `47`.

Add events. Prefer one compact event unless implementation needs separate lifecycle events:

```solidity
event ActiveRollupUpdated(address indexed oldRollup, address indexed newRollup, uint256 harvested);
```

Add errors:

```solidity
error StakingManager__RollupTransitionPending(address activeRollup, address canonicalRollup);
error StakingManager__NoRollupTransition();
error StakingManager__OldRollupRewardsStillClaimable(address oldRollup, uint256 claimableRewards);
```

## Rollup Helpers

Replace the current `_getRollup()` model with two concepts:

```solidity
function _getActiveRollup() internal view returns (address rollupAddress, IAztecRollup rollup)
```

This always returns `activeRollup`.

```solidity
function _getCanonicalRollup() internal view returns (address rollupAddress, IAztecRollup rollup)
```

This reads `rollupRegistry.getCanonicalRollup()`.

Add:

```solidity
function _revertIfRollupTransitionPending() internal view
```

This compares `activeRollup` against `rollupRegistry.getCanonicalRollup()` and reverts on mismatch.

## Reward Behavior

Update these functions to always use `activeRollup` and never revert merely because canonical changed:

- `harvestRewards()`
- `getClaimableRewards()`

This preserves accounting for rewards left behind on the old rollup.

`harvestRewards()` should keep the existing try/catch behavior, because current code intentionally treats harvest failure as non-fatal.

## Transition Function

Add a permissionless function:

```solidity
function transitionRollup() external nonReentrant returns (uint256 harvested)
```

Behavior:

1. Read `oldRollup = activeRollup`.
2. Read `newRollup = rollupRegistry.getCanonicalRollup()`.
3. Revert if `oldRollup == newRollup`.
4. Claim old-rollup rewards for `rewardsAccumulator`.
5. Verify old-rollup claimable rewards are now zero.
6. Set `activeRollup = newRollup`.
7. Emit `ActiveRollupUpdated(oldRollup, newRollup, harvested)`.

Make step 5 strict. If `claimSequencerRewards()` reverts or old rewards remain claimable, do not transition. This preserves the core invariant: old rewards are not dropped from accounting.

If old rewards are temporarily unclaimable because `isRewardsClaimable()` is false, transition remains blocked. That is consistent with the safety-first model, but tests and docs should explicitly cover it.

## Functions To Gate

These should revert while `activeRollup != canonicalRollup`:

- `stake()`
- `unstake()`
- `refreshAttesterState()`
- `purgeFailedQueueEntry()`
- `canStake()`

These all rely on live rollup state and should not operate across an unresolved cutover.

These local/cached views do not need to revert:

- `totalStaked()`
- `getStakingState()`
- `pendingUnstakes()`
- `hasFinalizedUnstakes()`
- basic local configuration views

## OllaCore Interaction

Because `getClaimableRewards()` keeps working against `activeRollup`, accounting continues to include old rewards during the pending transition.

Expected behavior during pending transition:

- Harvest can still run and drain old rewards.
- New stake is blocked through `canStake()` and `stake()`.
- Unstake is blocked until transition completes.

Block unstake for the first implementation. It is simpler and avoids mixing “active rollup for rewards” with “canonical rollup for moved validators.”

## Attester Exit Compatibility

Do not change existing `exitRollup` behavior.

The current code already stores the rollup where an exit was initiated and refreshes exiting attesters on that rollup. That remains necessary after this change.

The new `activeRollup` is for the manager’s active staking/reward target. It should not replace `exitRollup`.

## Tests

Add focused tests in `contracts/test/staking/staking-manager/StakingManagerRollupUpgrade.t.sol`.

Core cases:

1. `getClaimableRewards()` continues reading old active rollup after canonical changes.
2. `harvestRewards()` claims old active rollup rewards after canonical changes.
3. `transitionRollup()` claims old rewards and updates `activeRollup`.
4. `transitionRollup()` reverts when canonical has not changed.
5. `transitionRollup()` reverts or does not update if old reward claim fails.
6. `stake()` reverts while transition pending.
7. `unstake()` reverts while transition pending.
8. `refreshAttesterState()` reverts while transition pending for non-exiting/general refresh path.
9. `purgeFailedQueueEntry()` reverts while transition pending.
10. `canStake()` reverts while transition pending.
11. After successful transition, stake/unstake/refresh use the new canonical rollup.
12. Existing `exitRollup` tests still pass for exits initiated before rollup transition.

Accounting/e2e cases:

1. `OllaCore.accountingState()` includes old-rollup claimable rewards during pending transition.
2. `rebalance()` can harvest old-rollup rewards during pending transition.
3. After transition, `getClaimableRewards()` reads the new rollup.

## Verification Guidance

Do not build the entire project.

Do not run the entire test suite.

Ask the user/operator to run those commands if full verification is needed.

Run only targeted tests for this change, such as focused `StakingManagerRollupUpgrade` and reward/accounting tests. If broader validation is desired, ask the user/operator to run it.

## Audit Response Framing

Explain that Olla intentionally uses an explicit active-rollup pointer instead of automatically following Aztec canonical changes.

The invariant becomes:

```text
Rewards accounting always follows activeRollup.
Rollup-dependent staking operations are disabled while activeRollup != canonicalRollup.
A permissionless transition can update activeRollup only after old-rollup rewards are drained.
```

This addresses the audit finding by preventing old rewards from disappearing from accounting, while also preventing unsafe operator actions during the cutover.
