# Deterministic Accounting Finalization Implementation Plan

This plan covers issues #58, #59, #60 for implementing deterministic accounting finalization in OllaCore.

## Overview

Implement deterministic `updateAccounting()` that recomputes `totalAssets`, `exchangeRate`, and protocol fees from on-chain sources and wires SafetyModule breakers into the accounting path.

**Source of truth**: `research/technical/architecture/invariants.md`, `research/technical/architecture/interfaces-and-roles.md`, `research/technical/architecture/operations-and-controls.md`, `research/technical/architecture/launch-constraints.md`.

## Phase Summary

| Phase | Issue | Scope |
| --- | --- | --- |
| [Phase 1](./deterministic-accounting-phase1-validator-inputs.md) | #59 | Read Aztec validator deltas + assemble accounting inputs |
| [Phase 2](./deterministic-accounting-phase2-finalization.md) | #58 | Deterministic total assets, exchange rate, fee minting |
| [Phase 3](./deterministic-accounting-phase3-breakers.md) | #60 | Accounting liveness + breaker integration |

## Dependencies

- Fee parameter wiring and fee minting targets are owned by issue #46 (RewardsVault + fee distribution).

## Architecture Context

- Accounting invariant (`research/technical/architecture/invariants.md`):

```solidity
totalAssets = bufferedAssets
    + stakedPrincipal
    + rewardsVaultBalance
    + rewardsDelta
    - slashingDelta;
exchangeRate = totalAssets / stAztec.totalSupply();
grossRewards = (newTotalAssets - oldTotalAssets) - netFlows;
```

- `updateAccounting()` flow is operator-triggered and should not move AZTEC; it reads on-chain module data and updates snapshots, then mints protocol fee shares.
- SafetyModule checks for rate drop, queue ratio, and accounting liveness are required for each accounting update.

## Files to Create/Modify

| File | Description |
| --- | --- |
| `contracts/src/core/OllaCore.sol` | Implement deterministic accounting and fee minting, call SafetyModule checks, emit validator state event |
| `contracts/src/staking/interfaces/IAztecRollup.sol` | Add `getValidatorState` (or equivalent) to read rewards/slashing deltas |
| `contracts/src/core/interfaces/IOllaCore.sol` | Align validator state event naming/args if needed; update comments |
| `contracts/test/core/OllaCore.t.sol` | Unit tests for accounting math, rounding, fee minting, validator state read |
| `contracts/test/integration/OllaCoreSafetyModule.integration.t.sol` | Accounting breaker integration coverage |
| `contracts/test/integration/AztecInterfaceCompatibility.integration.t.sol` | Update Aztec interface compatibility tests for new rollup method |

## Verification

```bash
forge test --match-path "contracts/test/core/OllaCore.t.sol"
forge test --match-path "contracts/test/integration/OllaCoreSafetyModule.integration.t.sol"
forge test --match-path "contracts/test/integration/AztecInterfaceCompatibility.integration.t.sol"
```

## Spec Deviations and Improvement Opportunities

- **Validator state event naming**: Use `AttestersStateRead(...)` to match the current interface/event naming in `contracts/src/core/interfaces/IOllaCore.sol`.
- **Net flow sign handling**: Implement signed `netFlows` (allow negative) to align with `netFlows = netDeposits - netWithdrawals`; fee minting should still occur when `grossRewards > 0` even if netFlows is negative.
- **Aztec rollup access**: Use StakingManager as the source of validator deltas by reading rollup validator state; OllaCore should not store a direct rollup address.
- **Fee parameters**: Defer feeBps/treasurySplitBps wiring to the RewardsVault feature; keep accounting logic prepared to consume configured fee values once available.
