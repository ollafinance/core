# Phase 2: OllaCore Rebalance Coordination

**Issue**: #181 - improvement: bound rebalance work and enforce gas coordination

## Scope

- Track rebalance gas budget within OllaCore.
- Introduce shared gas thresholds for step transitions.
- Persist progress so rebalance completes across multiple calls.

## Prerequisites

- Phase 1 bounded staking/unstaking is complete.

## Implementation Steps

1. Add rebalance progress state and step model.
   - In `contracts/src/core/OllaCore.sol`, introduce:
     - `enum RebalanceStep { Harvest, PullUnstaked, FinalizeWithdrawals, InitiateUnstake, StakeSurplus, Done }`
     - `struct RebalanceProgress { RebalanceStep step; uint256 stakeRemaining; uint256 unstakeRemaining; }`
     - `RebalanceProgress private _rebalanceProgress;`
   - If operators need visibility, add `function rebalanceProgress() external view returns (RebalanceProgress memory);` in `contracts/src/core/interfaces/IOllaCore.sol`.

2. Add a single shared gas threshold for step transitions.
   - Define a constant such as `_REBALANCE_GAS_THRESHOLD` in `OllaCore`.
   - Add helper `_hasGasForStep()` to check `gasleft()` and return early if below threshold.
   - Pass the threshold into `StakingManager` (new setter or init param) so all loops share the same budget.

3. Refactor `rebalance()` into a resumable state machine.
   - On first entry (no progress), initialize the step order and compute stake/unstake targets based on `targetBufferedAssets`, pending withdrawals, and current buffers.
   - For each step:
     - Check `gasleft()` against the shared threshold; if below, persist `_rebalanceProgress` and return partial results.
     - Call bounded staking/unstaking/finalization functions and update `stakeRemaining` or `unstakeRemaining` in OllaCore.
     - Use `unstake()` return value (initiated amount) to decrement `unstakeRemaining`.
     - Advance step only when the current step is fully complete.
   - Emit `Rebalanced` only when the full sequence completes (step = Done), preserving existing event semantics.

4. Ensure no regressions in accounting updates.
   - Keep `_syncBufferedWithBalance()` at the start of the sequence and avoid double-application mid-progress.
   - Maintain existing buffer and staked principal updates only when actual stake/unstake amounts are confirmed.

5. Update interface and scripts if needed.
   - Update `contracts/src/core/interfaces/IOllaCore.sol` to include any new view or configuration functions.
   - Update `contracts/src/staking/interfaces/IStakingManager.sol` with a setter (e.g., `setRebalanceGasThreshold(uint256)`) and apply access control (only core).
   - Verify `contracts/script/ops/Rebalance.s.sol` still compiles and calls `rebalance()` correctly.

6. Calculate the gas budget and finalize threshold.
   - Benchmark worst-case step costs (stake, unstake, finalize) with many attesters and pending exits.
   - Set `_REBALANCE_GAS_THRESHOLD` to cover the most expensive single iteration plus return buffer.
   - Document the chosen budget and rationale in the plan or code comments.

## Test Cases from Issue

- [ ] Stake is now bounded work and completes as much staking actions as it is allowed to with the gas it has
- [ ] Unstake is now bounded work and completes as much unstaking actions as it is allowed with the gas it has
- [ ] Rebalance keeps track of it's gas usage and ensure that functions have enough funds

## Acceptance Criteria

- [ ] Rebalance never reverts due to running out of gas mid-sequence.
- [ ] Rebalance completes across multiple calls with persistent progress tracking.

## Verification

```bash
forge test --match-contract OllaCoreRebalanceTest -vvv
forge test --match-path contracts/test/integration/RebalanceIntegration.t.sol -vvv
```
