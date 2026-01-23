# Phase 1: SafetyModule Contract and Interface

**Issue**: #68 - feat: SafetyModule contract implementation

## Scope

- Implement SafetyModule state, roles, events, and core checks.
- Provide interface for OllaCore to call safety checks.

## Prerequisites

- None beyond current module layout.

## Implementation Steps

1. Create `contracts/src/interfaces/ISafetyModule.sol` based on `research/technical/architecture/components/safety-module.md` and `interfaces-and-roles.md`:
   - `checkDepositAllowed(uint256 deposit,uint256 total) external view returns (bool)`
   - `checkRateDrop(uint256 oldRate,uint256 nextRate) external`
   - `checkQueueRatio(uint256 queued,uint256 total) external`
   - `checkAccountingLiveness() external`
   - `checkWithdrawalMinimum(uint256 assets) external view`
    - `setDepositCap(uint256 cap) external`
   - `setWithdrawalMinimum(uint256 minimum) external`
    - `pause()` / `unpause()`
    - `isPaused() external view returns (bool)`
2. Implement `contracts/src/core/SafetyModule.sol`:
   - Storage: `depositCap`, `withdrawalMinimum`, `paused`, `minRateDropBps`, `maxQueueRatioBps`, `maxAccountingDelay`, `lastAccountingTimestamp`.
   - Roles: `GUARDIAN_ROLE`, `CORE_ROLE`, `DEFAULT_ADMIN_ROLE` (AccessControl).
   - Events: `Paused`, `Unpaused`, `DepositCapUpdated`, `WithdrawalMinimumUpdated`, `CircuitBreakerTriggered(bytes32)`, `RateDropLimitUpdated`, `QueueRatioLimitUpdated`.
   - `checkDepositAllowed` returns `false` if `deposit + total > depositCap`.
   - `checkWithdrawalMinimum` reverts (or returns false) if `assets < withdrawalMinimum`.
   - `checkRateDrop` compares `(oldRate - nextRate)` vs `minRateDropBps` and triggers the breaker on breach.
   - `checkQueueRatio` compares `(queued * 10_000) / total` to `maxQueueRatioBps` and triggers the breaker on breach.
   - `checkAccountingLiveness` compares `block.timestamp - lastAccountingTimestamp` to `maxAccountingDelay` and triggers the breaker on breach.
   - `pause` / `unpause` toggle `paused` and emit events.
3. Standardize breaker reasons as `bytes32` constants (e.g., `RATE_DROP`, `QUEUE_RATIO`, `ACCOUNTING_STALE`) and emit `CircuitBreakerTriggered` with the reason.
4. Add unit tests in `contracts/test/core/SafetyModule.t.sol`:
   - Role-gated access for `pause`, `unpause`, `setDepositCap`.
   - Role-gated access for `setWithdrawalMinimum`.
   - Breaker triggers set `paused = true` and emit `CircuitBreakerTriggered`.
   - `checkDepositAllowed` returns `false` when cap is exceeded.
   - `checkWithdrawalMinimum` reverts (or returns false) when below minimum.

## Test Cases from Issue

- [ ] Role-gated setters and pause/unpause.
- [ ] Withdrawal minimum setter is role-gated.
- [ ] Circuit breaker emits reason.

## Acceptance Criteria

- [ ] All functions and events listed above are present and wired.
- [ ] Withdrawal minimum checks and setter are present.

## Verification

```bash
forge test --match-contract SafetyModule -vvv
```

## Potential Improvements

- Add explicit admin setters for `minRateDropBps`, `maxQueueRatioBps`, and `maxAccountingDelay` with events to match the architecture spec.
- Standardize `bytes32` breaker reasons (e.g., `RATE_DROP`, `QUEUE_RATIO`, `ACCOUNTING_STALE`) in a shared constants library for consistent tests and analytics.
