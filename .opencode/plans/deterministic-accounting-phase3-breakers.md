# Phase 3: Accounting Liveness and Breaker Integration

**Issue**: #60 - feat: Accounting liveness + breaker integration

## Scope

- Track accounting liveness on each successful update.
- Call SafetyModule breaker checks in the accounting path:
  - `checkRateDrop(oldRate, newRate)`
  - `checkQueueRatio(totalPendingAssets, totalAssets)`
  - `checkAccountingLiveness()`
- Pause protocol via SafetyModule on breaker trigger (SafetyModule handles pause internally).

## Prerequisites

- Phase 2 complete with deterministic `updateAccounting()`.

## Implementation Steps

1. **Accounting liveness timestamp**
   - After successful accounting update, call `ISafetyModule.setLastAccountingTimestamp(block.timestamp)`.
   - Ensure it runs only after all accounting state updates and fee minting succeed.

2. **Breaker checks in accounting flow**
   - Before updating the report, call:

```solidity
safetyModule.checkAccountingLiveness();
safetyModule.checkRateDrop(oldRate, newRate);
safetyModule.checkQueueRatio(withdrawalQueue.totalPendingAssets(), newTotalAssets);
```

3. **Paused state handling**
   - Respect pause behavior from `operations-and-controls.md` (deposits disabled when paused; withdrawal requests allowed; finalization disabled).
   - Ensure `updateAccounting()` still runs when paused if policy permits (documented or enforced by design).

## Test Cases from Issue

- [ ] Stale accounting triggers pause via `checkAccountingLiveness`.
- [ ] Rate drop over threshold triggers pause.
- [ ] Queue ratio limit enforced.

## Acceptance Criteria

- [ ] SafetyModule breakers are wired into accounting path and use correct inputs.

## Verification

```bash
forge test --match-path "contracts/test/integration/OllaCoreSafetyModule.integration.t.sol"
```
