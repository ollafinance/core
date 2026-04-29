NEVER build the entire project
NEVER run the entire test-suite

For the above points, always refer to the user/operator to run these commands.

# Plan: Track Legacy Rollups For Claimable Rewards

## Goal

Fix the reward accounting blind spot where unclaimed sequencer rewards on a previous Aztec rollup stop being counted after `rollupRegistry.getCanonicalRollup()` changes.

Use the auditors' recommended approach: keep tracking legacy rollups until their rewards are fully harvested, while still allowing the protocol to continue operating without an explicit rollup-transition pause.

## High-Level Design

`StakingManager` should maintain a small list of reward rollups to query and harvest from.

In the normal case, this list contains one rollup: the current canonical rollup.

When the canonical rollup changes, accounting should automatically include both:

- Legacy rollups already stored in the tracked list.
- The current canonical rollup from `rollupRegistry.getCanonicalRollup()`.

Legacy rollups remain tracked until their claimable rewards for `rewardsAccumulator` are emptied.

## Important Constraints

- `getClaimableRewards()` must remain a `view` function.
- `getClaimableRewards()` should not mutate storage when it detects a canonical rollup change.
- `getClaimableRewards()` should sum rewards from the stored rollup list and also include the current canonical rollup if it is not already stored.
- Rapid upgrade sequences like A -> B -> C where B was never observed on-chain do not need special handling.
- Accounting should avoid halting where possible. Reverts and failures from individual rollups should be captured instead of causing the whole accounting read or harvest to fail.
- Rollups should only be removed from tracking once their rewards are confirmed empty.

## Stored State

Add tracked reward rollup state to `StakingManager`:

- `address[] private _rewardRollups;`
- `mapping(address rollup => bool tracked) private _isRewardRollup;`

Initialize the list with the canonical rollup during initialization, if appropriate for upgrade safety. If this is added via contract upgrade, provide an initializer or migration path that registers the current canonical rollup.

## `getClaimableRewards()` Behavior

`getClaimableRewards()` remains `external view onlyCore returns (uint256)`.

It should:

1. Load the current canonical rollup from `rollupRegistry.getCanonicalRollup()`.
2. Loop over `_rewardRollups`.
3. For each stored rollup, attempt `getSequencerRewards(address(rewardsAccumulator))`.
4. Add successful results to the total.
5. Capture failures instead of reverting.
6. If the canonical rollup was not already included in `_rewardRollups`, query it separately and add the successful result.
7. Return the summed claimable rewards.

This preserves view semantics while making accounting automatically aware of a canonical rollup change before any state-changing sync has occurred.

## Failure Policy For View Accounting

The preferred policy is non-halting accounting.

If a tracked rollup reverts on `getSequencerRewards`, `getClaimableRewards()` should skip that rollup and continue summing other rollups.

This means accounting may temporarily undercount rewards from a failing rollup, but it avoids halting protocol accounting and user flows because of one broken or stale dependency.

If visibility is needed, add a state-changing diagnostic or harvest-time event for failed rollup reads. A pure view function cannot emit events.

## `harvestRewards()` Behavior

`harvestRewards()` should harvest from all relevant rollups and prune drained legacy rollups.

It should:

1. Ensure the current canonical rollup is tracked in storage.
2. Loop over `_rewardRollups`.
3. Attempt `claimSequencerRewards(rewardsAccumulator)` on each rollup.
4. Add successful claimed amounts to `harvested`.
5. Capture claim failures and keep the rollup tracked.
6. After a successful claim, query `getSequencerRewards(address(rewardsAccumulator))`.
7. If remaining rewards are zero and the rollup is not the current canonical rollup, remove it from `_rewardRollups`.
8. Never remove a rollup if the post-claim reward query fails.
9. Never remove the current canonical rollup solely because it has zero rewards.

This keeps the list normally at one rollup while preserving legacy rollups long enough to drain their pending rewards.

## Rollup Removal Rule

A rollup can be removed from tracking only when all of the following are true:

- It is not the current canonical rollup.
- A reward query succeeds.
- `getSequencerRewards(address(rewardsAccumulator)) == 0` after any harvest attempt.

Do not remove on claim failure.

Do not remove on reward-query failure.

Do not remove the canonical rollup.

## Canonical Rollup Sync

Add an internal helper such as `_ensureCanonicalRewardRollup()`.

It should:

1. Read `rollupRegistry.getCanonicalRollup()`.
2. If not tracked, append it to `_rewardRollups` and mark `_isRewardRollup[canonical] = true`.
3. Return the canonical rollup address.

Use this helper in state-changing functions that already interact with rollup state, especially `harvestRewards()`.

`getClaimableRewards()` should not use this helper because it must remain view-only.

## Events

Consider adding events:

- `RewardRollupTracked(address indexed rollup)`
- `RewardRollupRemoved(address indexed rollup)`
- `RewardRollupRewardReadFailed(address indexed rollup, bytes reason)` for state-changing contexts only
- `RewardsHarvestFailed(address indexed rollup, bytes reason)` or extend the existing event pattern if interface compatibility allows
- `RewardsHarvestedFromRollup(address indexed rollup, uint256 amount)` if per-rollup observability is useful

View reads cannot emit events, so failures inside `getClaimableRewards()` can only be silently skipped or exposed through a separate non-view diagnostic function.

## Testing Scope

Do not run the entire project build.

Do not run the entire test suite.

Ask the user/operator to run full build or full-suite commands if needed.

Focused tests to add or update:

- `getClaimableRewards()` returns rewards from the stored legacy rollup after canonical changes.
- `getClaimableRewards()` includes the new canonical rollup even before it has been persisted into `_rewardRollups`.
- `getClaimableRewards()` sums legacy plus canonical rewards.
- `getClaimableRewards()` skips a reverting legacy rollup and still returns rewards from healthy rollups.
- `harvestRewards()` claims from both legacy and canonical rollups.
- `harvestRewards()` tracks the new canonical rollup in storage.
- `harvestRewards()` removes a legacy rollup only after its rewards are zero.
- `harvestRewards()` keeps a legacy rollup when claim fails.
- `harvestRewards()` keeps a legacy rollup when the post-claim reward query fails.
- `harvestRewards()` never removes the current canonical rollup just because rewards are zero.

Run only focused Foundry tests for the touched staking-manager reward and rollup-upgrade test files, or ask the user/operator to run broader coverage.
