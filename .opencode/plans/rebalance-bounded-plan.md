# Rebalance Bounded Work Implementation Plan

This plan covers issue #181 for bounding rebalance work and enforcing gas coordination.

## Overview

Rebalance currently performs harvest, unstake, withdrawal finalization, and stake in a single call. This plan introduces bounded staking/unstaking loops, persistent progress tracking, and gas-aware step transitions so rebalance can complete across multiple calls without reverting mid-sequence.

## Phase Summary

| Phase | Issue | Scope |
| --- | --- | --- |
| [Phase 1](./rebalance-bounded-phase1-staking-manager.md) | #181 | Bounded stake/unstake loops with cursors |
| [Phase 2](./rebalance-bounded-phase2-olla-core.md) | #181 | Rebalance state machine and gas coordination |
| [Phase 3](./rebalance-bounded-phase3-tests.md) | #181 | Unit + integration tests for bounded rebalance |

## Architecture Context

OllaCore.rebalance orchestrates:

- SafetyModule liveness check
- Harvest rewards via StakingManager
- Pull unstaked funds via StakingManager
- Finalize withdrawals via WithdrawalQueue
- Initiate new unstakes via StakingManager
- Stake surplus via StakingManager

After this change, OllaCore will maintain a rebalance progress record and only advance steps when enough gas remains, while StakingManager loops run with bounded work and cursors so operators can safely call rebalance multiple times to finish a sequence.

## Files to Create/Modify

| File | Description |
| --- | --- |
| contracts/src/staking/StakingManager.sol | Add bounded loops, cursors, gas thresholds |
| contracts/src/staking/interfaces/IStakingManager.sol | Update signatures/results for bounded operations |
| contracts/src/core/OllaCore.sol | Add rebalance progress state + gas coordination |
| contracts/src/core/interfaces/IOllaCore.sol | Expose rebalance progress and new config if needed |
| contracts/src/staking/mocks/MockStakingManager.sol | Align mocks with new interfaces |
| contracts/test/mocks/MockAccountingStakingManager.sol | Align mocks with new interfaces |
| contracts/test/core/OllaCoreRebalance.t.sol | Add bounded rebalance tests |
| contracts/test/staking/StakingManager.t.sol | Add bounded stake/unstake tests |
| contracts/test/integration/RebalanceIntegration.t.sol | End-to-end multi-call rebalance |

## Verification

```bash
forge test --match-contract OllaCoreRebalanceTest -vvv
forge test --match-contract StakingManagerTest -vvv
forge test --match-path contracts/test/integration/RebalanceIntegration.t.sol -vvv
```
