# Bug Fix Notes

This file tracks bug fixes made while adding/reproducing integration tests.

Template:
- Bug:
- Fix:
- Files:
- Why:
- Tests:

## Progress (2026-02-09)

- Bug: OllaCore rebalance underflow when `initiated > unstakeRemaining` (discrete attester chunks can overshoot).
- Fix: Clamp `unstakeRemaining` to 0 when `initiated >= unstakeRemaining`.
- Files: `contracts/src/core/OllaCore.sol`
- Why: Prevent `progress.unstakeRemaining -= initiated` reverting with panic 0x11 during `RebalanceStep.InitiateUnstake`.
- Tests: `forge test --match-test test_UnstakeUnderflow_Bug_InitiatedExceedsRequested -vv` (PASS)

- Bug: External exits can keep `rebalance()` stuck in `PullUnstaked` because `hasExitableUnstakes()` observes exits on activated attesters, but `getUnstakedFunds()` only finalizes pending list.
- Fix: Sync externally-exited activated attesters into `_pendingUnstakeRequests` before finalizing exits (so they can be finalized/claimed).
- Files: `contracts/src/staking/StakingManager.sol`
- Why: Ensure externally-initiated exits are claimable by the protocol without requiring an explicit `cleanActivatedAttesters()` call.
- Tests: `forge test --match-test test_ExternalExit_Bug_FundsStuckInActivatedAttesters -vv` (PASS)

- Note: The integration test assertion was updated to measure the vault's token balance delta (claim) instead of `bufferedAssets` delta, since the same `rebalance()` call can both claim exits and finalize withdrawals.
- Files: `contracts/test/integration/ExternalExitIntegration.t.sol`
