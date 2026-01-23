# SafetyModule Implementation Plan

This plan covers issues #67, #68, #69, #70, #71, #93 for implementing the SafetyModule, deposit caps, circuit breakers, paused flow validation, and a withdrawal minimum.

## Overview

The SafetyModule enforces protocol safety controls:

- Deposit caps (TVL ceiling).
- Circuit breakers for rate-drop anomalies, queue pressure, and accounting liveness.
- Paused-state behavior for core flows.

**Source of truth**: `research/technical/architecture/components/safety-module.md`, `research/technical/architecture/flows.md`, `research/technical/architecture/interfaces-and-roles.md`, `research/technical/architecture/invariants.md`.

## Phase Summary

| Phase | Issue | Scope |
| --- | --- | --- |
| [Phase 1](./safety-module-phase1-contract.md) | #68 | SafetyModule contract, interface, events, roles |
| [Phase 2](./safety-module-phase2-deposit-cap.md) | #71 | Deposit cap checks in `OllaCore.deposit` |
| [Phase 3](./safety-module-phase3-breakers-paused.md) | #69, #70, #67, #93 | Circuit breaker integrations + paused flow validation + withdrawal minimum |

## Architecture Context

- `OllaCore.deposit` must call SafetyModule before share calculation (flow spec).
- `OllaCore.updateAccounting` must call rate-drop and liveness checks before publishing the new exchange rate.
- `OllaCore.finalizeWithdrawals` must enforce queue-pressure checks using pending assets from `WithdrawalQueue`.
- Withdrawal requests must meet the minimum configured in SafetyModule before any share conversion or queue enqueue.
- Paused behavior follows the spec: deposits disabled, withdrawal requests allowed, finalization disabled, claims allowed.
- Roles follow `interfaces-and-roles.md`: guardian controls pause/unpause and admin config.

## Files to Create/Modify

| File | Description |
| --- | --- |
| `contracts/src/core/SafetyModule.sol` | SafetyModule implementation and storage layout |
| `contracts/src/interfaces/ISafetyModule.sol` | Interface for SafetyModule checks and configuration |
| `contracts/src/core/OllaCore.sol` | Integrate SafetyModule checks and paused flow gating |
| `contracts/src/interfaces/IOllaCore.sol` | Add any SafetyModule references/events needed by integration |
| `contracts/src/core/WithdrawalQueue.sol` | Potential enforcement location for withdrawal minimum |
| `contracts/src/interfaces/IWithdrawalQueue.sol` | Potential interface change for minimum checks |
| `contracts/test/core/SafetyModule.t.sol` | Unit tests for SafetyModule roles and breakers |
| `contracts/test/core/OllaCoreSafetyModule.t.sol` | Integration tests for deposit cap, breakers, paused flows |
| `contracts/test/core/WithdrawalMinimum.t.sol` | Unit/integration tests for minimum withdrawal amount |

## Verification

```bash
forge test --match-contract SafetyModule -vvv
forge test --match-contract OllaCoreSafetyModule -vvv
```
