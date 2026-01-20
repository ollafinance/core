# Phase 2: OllaCore requestWithdrawal Wiring

**Issue**: #56 - feat: OllaCore requestWithdrawal wiring

## Scope

Replace the current pending-withdrawal path with ERC-7540 async request flow. Burn stAztec shares, compute `assetsExpected` using exchange rate at request time, and enqueue on `WithdrawalQueue`.

## Prerequisites

- Phase 1 queue contract and interface implemented.
- Implement ERC-7540 async entry points in `IOllaCore`.

## Implementation Steps

1. Update `IOllaCore` to include `requestRedeem(uint256 shares, address receiver) returns (uint256 requestId)` and align events to `WithdrawalRequested` per architecture spec.
   - Enforce a single active request per user (revert if one already exists).
   - Return a non-zero, monotonically increasing request id per request.
2. Refactor `contracts/src/core/OllaCore.sol`:
   - Add `IWithdrawalQueue` interface import and typed storage for queue.
   - Remove `_pendingWithdrawals` and `claimPendingWithdraw` (fully async withdrawals only).
   - In `requestRedeem`, compute `assetsExpected = shares * exchangeRate / 1e18` (floor), burn shares, increment cumulativeWithdrawals by `assetsExpected`.
   - Call `WithdrawalQueue.requestWithdrawal(receiver, shares, assetsExpected, exchangeRate)` and emit `WithdrawalRequested` with request id.
   - Adjust pause logic so `requestRedeem` is allowed when paused (per spec).
   - Remove `previewRedeem`/`previewWithdraw` from the interface and implementation.
3. Update tests:
   - Add `OllaCoreWithdrawalQueue.t.sol` with request flow tests.
   - Validate share burn, assetsExpected locked, event payloads, and stored request in queue.
4. Remove legacy tests covering synchronous withdrawals and replace with queue-based flow tests.

## Test Cases from Issue

- [ ] User share balance decreases on request.
- [ ] `assetsExpected` uses the exchange rate at the time of request.
- [ ] Event payload matches stored request data.
- [ ] Second request from same user reverts while the first is active.

## Acceptance Criteria

- [ ] Request flow locks value deterministically and cannot be altered by later rate changes.

## Verification

```bash
forge test --match-contract OllaCoreWithdrawalQueueTest -vvv
```

## AI Prompt

Implement Phase 2 ERC-7540 requestRedeem wiring in OllaCore.
Focus on:
- contracts/src/core/OllaCore.sol
- contracts/src/interfaces/IOllaCore.sol
- contracts/test/core/OllaCoreWithdrawalQueue.t.sol
Requirements:
- Replace pending-withdrawal mapping with WithdrawalQueue integration.
- requestRedeem burns stAztec, computes assetsExpected using exchangeRate at request time, enqueues in queue, emits WithdrawalRequested.
- Allow requestRedeem while paused; ensure other pause semantics unchanged where appropriate.
- Enforce one active request per user (mapping from owner -> requestId).
- Tests: share burn, locked assetsExpected, event data matches queue storage.
Return code and tests.
