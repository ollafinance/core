# Phase 3: Withdrawal Finalization Wiring

**Issue**: #55 - feat: Withdrawal finalization wiring

## Scope

Wire `OllaCore.finalizeWithdrawals` to the queue and decrement buffered assets by finalized amount. Finalization must be blocked when paused.

## Prerequisites

- Phase 1 queue implementation.
- Phase 2 request flow integrated.

## Implementation Steps

1. Update `OllaCore.finalizeWithdrawals(uint256 available)`:
   - Require `onlyRole(OPERATOR_ROLE)` and `whenNotPaused` (paused blocks finalization only).
   - Call `WithdrawalQueue.finalizeWithdrawals(available)` to get `used`.
   - Decrease `_accountingState.bufferedAssets` by `used` and sync balance.
   - Emit `WithdrawalFinalized(available, used)`.
2. Ensure `available` is computed by caller (rebalance path) and is bounded by buffered assets.
3. Tests:
   - Partial liquidity finalizes earliest requests only.
   - Buffered assets decrease by `used`.
   - Finalized requests become claimable.
4. Add fuzz test for varying liquidity to ensure FIFO and no over-consumption.

## Test Cases from Issue

- [ ] Finalization uses only available liquidity.
- [ ] Buffered assets decrease by finalized amount.
- [ ] Finalized requests are claimable.

## Acceptance Criteria

- [ ] Finalization processes requests strictly FIFO.
- [ ] If liquidity is insufficient, only earliest requests finalize.

## Verification

```bash
forge test --match-contract OllaCoreWithdrawalQueueTest -vvv
```

## AI Prompt

Implement Phase 3 finalization wiring.
Focus on:
- contracts/src/core/OllaCore.sol
- contracts/test/core/OllaCoreWithdrawalQueue.t.sol
Requirements:
- OllaCore.finalizeWithdrawals calls WithdrawalQueue.finalizeWithdrawals and decrements buffered assets by used.
- Finalization is blocked when paused; requests/claims are still allowed.
- Tests cover partial liquidity FIFO behavior and buffered assets accounting.
Return code and tests.