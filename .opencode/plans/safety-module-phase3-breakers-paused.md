# Phase 3: Circuit Breakers and Paused Flows

**Issues**: #69 - feat: SafetyModule (caps + circuit breakers), #70 - feat: Circuit breaker integration, #67 - feat: Paused state behavior validation

## Scope

- Integrate rate-drop, queue ratio, and accounting liveness checks.
- Ensure paused behavior across core flows matches the architecture spec.
- Enforce withdrawal minimum during withdrawal request flow.

## Prerequisites

- Phase 1 SafetyModule contract and interface.
- Phase 2 deposit cap check integration.

## Implementation Steps

1. Wire rate-drop checks in `contracts/src/core/OllaCore.sol`:
   - Capture `oldRate = _latestReport.exchangeRate` before `updateAccounting` calculations.
   - After computing the new rate (but before writing state), call `safetyModule.checkRateDrop(oldRate, newRate)`.
   - If SafetyModule pauses on breach, ensure `updateAccounting` propagates the reverted/pause state consistently.
2. Wire accounting liveness:
   - After a successful `updateAccounting`, update `SafetyModule.lastAccountingTimestamp` via `checkAccountingLiveness()` or a dedicated setter.
   - Add a periodic operator call path to `checkAccountingLiveness()` (e.g., as part of `updateAccounting`).
3. Wire queue ratio checks in `OllaCore.finalizeWithdrawals`:
   - Read `queued = IWithdrawalQueue.totalPendingAssets()` and `total = totalAssets()`.
   - Call `checkQueueRatio(queued, total)` before finalization.
4. Paused behavior alignment:
    - Ensure `deposit` fails when either core or SafetyModule is paused.
    - Ensure `requestRedeem` is allowed even when paused.
    - Ensure `finalizeWithdrawals` is blocked when paused.
    - Ensure `claimWithdrawal` is allowed when paused (queue handles claiming logic).
5. Enforce withdrawal minimum in `requestRedeem` or queue enqueue path:
    - Call `safetyModule.checkWithdrawalMinimum(shares)` before any queue write.
    - Revert with a dedicated error when the check fails.
6. Tests in `contracts/test/core/OllaCoreSafetyModule.t.sol`:
    - Rate-drop, queue ratio, and liveness thresholds trigger SafetyModule pause and emit `CircuitBreakerTriggered`.
    - Deposits fail during paused state; withdrawal requests and claims succeed; finalization blocked.
    - Withdrawal requests below minimum revert; at minimum succeed.

## Test Cases from Issues

- [ ] Deposit cap blocks deposits above limit.
- [ ] Rate-drop and queue ratio triggers pause.
- [ ] Accounting liveness pauses when stale.
- [ ] Withdrawal minimum rejects smaller share requests.
- [ ] Each flow respects paused state.

## Acceptance Criteria

- [ ] SafetyModule enforces caps and breakers with correct inputs.
- [ ] Breaker checks are wired into core flows with correct inputs.
- [ ] Withdrawal minimum (shares) enforced at request time.
- [ ] Paused behavior matches defined flow above.

## Verification

```bash
forge test --match-contract OllaCoreSafetyModule -vvv
```

## Potential Improvements

- Ensure `OllaCore` consults `ISafetyModule.isPaused()` in addition to `Pausable` to avoid split-brain pause states.
