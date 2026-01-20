# Phase 4: Withdrawal Claim Flow

**Issue**: #57 - feat: Withdrawal claim flow

## Scope

Allow users to claim finalized withdrawal requests and transfer locked assets from OllaCore. Claims must be allowed while paused.

## Prerequisites

- Phases 1-3 completed.

## Implementation Steps

1. Implement claim via `redeem(uint256 shares, address receiver)` in `OllaCore` (no `withdraw`).
   - Keep a non-standard `claimRedeem(uint256 requestId)` helper to claim a specific FIFO request id.
   - `redeem` should ignore the `shares` input and consume the caller's full finalized request (single active request per user).
   - `claimRedeem` calls `WithdrawalQueue.claim(requestId)`; receive `assetsExpected` and stored receiver from queue.
   - Transfer assets to the request receiver and emit `WithdrawalClaimed(requestId, receiver, assetsExpected)`.
   - Ensure no reentrancy (use `nonReentrant`).
2. Ensure queue `claim` returns receiver info or expose `getRequest` to resolve receiver on core side.
3. Ensure claim is allowed while paused (no `whenNotPaused`).
4. Confirm queue claim prevents double-claim, and OllaCore transfer uses locked `assetsExpected`.
5. Tests:
   - Claim fails if not finalized.
   - Double claim reverts.
   - Asset transfer equals locked `assetsExpected`.
   - Claims allowed while paused (finalization blocked).
   - Redeem ignores `shares` input and claims full finalized request.

## Test Cases from Issue

- [ ] Claim fails if request not finalized.
- [ ] Second claim for same id reverts.
- [ ] Transfer amount equals locked `assetsExpected`.
- [ ] Redeem ignores `shares` input and claims full finalized request.

## Acceptance Criteria

- [ ] Claims are available even when protocol is paused.

## Verification

```bash
forge test --match-contract OllaCoreWithdrawalQueueTest -vvv
```

## AI Prompt

Implement Phase 4 claim flow.
Focus on:
- contracts/src/core/OllaCore.sol
- contracts/test/core/OllaCoreWithdrawalQueue.t.sol
Requirements:
- redeem ignores `shares` and consumes the caller's finalized request, emitting WithdrawalClaimed.
- claimRedeem calls WithdrawalQueue.claim, transfers locked assets to stored receiver, emits WithdrawalClaimed.
- Claim allowed while paused; finalization blocked while paused.
- Tests: non-finalized claim revert, double claim revert, transfer amount locked.
Return code and tests.
