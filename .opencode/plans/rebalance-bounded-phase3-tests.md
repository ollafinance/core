# Phase 3: Tests and Regression Coverage

**Issue**: #181 - improvement: bound rebalance work and enforce gas coordination

## Scope

- Add test coverage for bounded staking/unstaking loops.
- Add test coverage for multi-call rebalance completion.
- Ensure existing rebalance behavior and accounting invariants do not regress.

## Prerequisites

- Phase 1 and Phase 2 changes merged locally.

## Implementation Steps

1. StakingManager bounded loop tests.
   - In `contracts/test/staking/StakingManager.t.sol`, add cases that:
     - Stake with a limited gas stipend and verify partial progress without revert.
     - Unstake with a limited gas stipend and verify progress + remaining tracking.
     - Resume unstake and confirm completion across multiple calls.

2. Rebalance multi-call tests.
   - In `contracts/test/core/OllaCoreRebalance.t.sol`, add cases that:
     - Call `rebalance()` with low gas so only the earliest steps execute.
     - Repeat calls until all steps finish and verify `Rebalanced` emits once.
     - Validate buffered assets, staked principal, and withdrawal queue state after completion.

3. Integration coverage.
   - In `contracts/test/integration/RebalanceIntegration.t.sol`, add end-to-end cases that:
     - Use many attesters/pending unstakes to force bounded work.
     - Ensure rebalance completes across multiple calls with correct final accounting.

4. Mock alignment.
   - Update tests and mocks to use new `IStakingManager` signatures and progress APIs.

## Test Cases from Issue

- [ ] Stake is now bounded work and completes as much staking actions as it is allowed to with the gas it has
- [ ] Unstake is now bounded work and completes as much unstaking actions as it is allowed with the gas it has
- [ ] Rebalance keeps track of it's gas usage and ensure that functions have enough funds

## Acceptance Criteria

- [ ] Stake work is bounded and always makes progress when possible.
- [ ] Unstake work is bounded and always makes progress when possible.
- [ ] Rebalance never reverts due to running out of gas mid-sequence.
- [ ] Rebalance completes across multiple calls with persistent progress tracking.

## Verification

```bash
forge test --match-contract StakingManagerTest -vvv
forge test --match-contract OllaCoreRebalanceTest -vvv
forge test --match-path contracts/test/integration/RebalanceIntegration.t.sol -vvv
```
