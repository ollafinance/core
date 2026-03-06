# High-Priority E2E Tests Implementation Plan

This plan covers 5 test suites targeting the most critical cross-contract interaction gaps in the Olla protocol. These are full-stack end-to-end tests that wire up all real contracts and exercise multi-step user journeys — distinct from the existing `*.integration.t.sol` tests which focus on 2-3 contract interactions.

## Overview

The existing test suite has strong unit-level coverage and some integration tests for the core happy paths (deposit -> rebalance -> withdraw). However, several critical cross-contract interaction patterns remain untested:

- Governance parameter changes interacting with the rebalance state machine
- Fee minting and distribution correctness across the treasury/provider split
- Multiple SafetyModule circuit breakers firing in sequence
- Buffer contention between instant redemption and async withdrawal queues
- ERC-2612 permit signature flows for gasless deposits and redeem requests

## Phase Summary

| Phase | Scope | Tests | Risk |
| --- | --- | --- | --- |
| [Phase 1](./e2e-phase1-governance-rebalance.md) | Governance parameter changes during/between rebalance cycles | 4 | Critical |
| [Phase 2](./e2e-phase2-fee-distribution.md) | Fee minting, share dilution, treasury/provider split | 5 | Critical |
| [Phase 3](./e2e-phase3-circuit-breaker-cascades.md) | SafetyModule circuit breaker cascades and recovery | 5 | High |
| [Phase 4](./e2e-phase4-instant-redeem-async-queue.md) | Instant redemption + async withdrawal buffer contention | 6 | High |
| [Phase 5](./e2e-phase5-permit-flows.md) | ERC-2612 permit deposit and redeem request flows | 7 | Medium |

## Architecture Context

```
User Flows Under Test:

  [Governance]──schedule──>┐
                           ▼
  [User]──deposit/permit──>[OllaVault]──>[OllaCore]──rebalance──>[StakingManager]
  [User]──instantRedeem───>[OllaVault]    │    │                       │
  [User]──requestRedeem───>[OllaVault]    │    ├──>[RewardsAccumulator]─┘
                               │          │    ├──>[SafetyModule] (circuit breakers)
                               ▼          │    └──>[OllaVault.mintFees()]──>[StAztec]
                        [WithdrawalQueue]──┘              │
                               │                    ┌─────┘
                               ▼                    ▼
                           [User claims]    [Treasury + Provider]
```

## Shared Test Harness

All 5 phases use a common full-stack setup with **real implementations** (no mocks except MockAztec token and MockAztecRollup/Registry for the Aztec L1 layer which is external):

```
Real Contracts:
  OllaCore, OllaVault, WithdrawalQueue, StAztec, SafetyModule,
  StakingManager, StakingProviderRegistry, RewardsAccumulator,
  OllaGovernance (phases 1-2)

Mocks (external dependencies only):
  MockAztec (ERC-20 asset token)
  MockAztecRollup + MockAztecRollupRegistry (Aztec L1 staking)
  MockAccountingStakingManager (phases 3-5 where real staking is not the focus)

Actors:
  governance        — OllaGovernance admin (proposer/executor/canceller)
  guardian          — SafetyModule pause/unpause role
  admin             — SafetyModule DEFAULT_ADMIN_ROLE (parameter setter)
  providerAdmin     — StakingProviderRegistry key manager
  operator          — permissionless rebalance caller
  alice, bob        — end users
  treasury          — protocol fee recipient address
  providerRewards   — staking provider fee recipient address
```

## Files to Create

| File | Description |
| --- | --- |
| `contracts/test/e2e/GovernanceRebalanceInteraction.e2e.t.sol` | Phase 1: Gov param changes vs rebalance state |
| `contracts/test/e2e/FeeMintingDistribution.e2e.t.sol` | Phase 2: Fee math and share minting e2e |
| `contracts/test/e2e/CircuitBreakerCascades.e2e.t.sol` | Phase 3: SafetyModule breaker sequences |
| `contracts/test/e2e/InstantRedeemAsyncQueue.e2e.t.sol` | Phase 4: Buffer contention scenarios |
| `contracts/test/e2e/PermitFlows.e2e.t.sol` | Phase 5: ERC-2612 permit signatures |

## Verification

```bash
# Run all e2e tests
forge test --match-path "test/e2e/*" -vvv

# Run individual phases
forge test --match-contract GovernanceRebalanceInteractionE2ETest -vvv
forge test --match-contract FeeMintingDistributionE2ETest -vvv
forge test --match-contract CircuitBreakerCascadesE2ETest -vvv
forge test --match-contract InstantRedeemAsyncQueueE2ETest -vvv
forge test --match-contract PermitFlowsE2ETest -vvv

# Coverage for e2e tests
forge coverage --match-path "test/e2e/*"
```
