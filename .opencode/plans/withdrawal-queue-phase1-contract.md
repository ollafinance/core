# Phase 1: WithdrawalQueue Contract

**Issue**: #54 - feat: WithdrawalQueue contract implementation

## Scope

Implement the FIFO WithdrawalQueue contract, interface, and core unit/fuzz tests. Use UUPS upgradeability and AccessControl roles.

## Prerequisites

- Confirm UUPS upgrade standard used across modules.
- Confirm core role assignment (OllaCore gets `CORE_ROLE`, guardian gets `DEFAULT_ADMIN_ROLE`).

## Implementation Steps

1. Add `IWithdrawalQueue` interface at `contracts/src/interfaces/IWithdrawalQueue.sol`.
   - Define `WithdrawalRequest` struct with `user`, `shares`, `assetsExpected`, `rate`, `finalized`, `claimed`.
   - Add function signatures per spec: `requestWithdrawal`, `finalizeWithdrawals`, `claim`, `getRequest`, `nextUnfinalized`.
2. Create `contracts/src/core/WithdrawalQueue.sol`.
   - Inherit `Initializable`, `AccessControlUpgradeable`, `UUPSUpgradeable`, `ReentrancyGuard`.
   - Storage layout: `address core`, `uint256 nextRequestId`, `uint256 nextPendingId`, `mapping(uint256 => WithdrawalRequest) requests`, `uint256 totalPendingAssets`, plus gap.
   - Implement `initialize(address core_, address admin_)` and role grants.
   - `requestWithdrawal`: only `CORE_ROLE`, increment id, store request, update `totalPendingAssets` and `nextRequestId`, emit `WithdrawalRequested`.
   - `finalizeWithdrawals(uint256 available)`: only `CORE_ROLE`, iterate FIFO from `nextPendingId` while available >= request.assetsExpected, mark finalized, advance pointer, decrement `totalPendingAssets`, emit `WithdrawalFinalized` per request, return `used`.
   - `claim(uint256 id)`: require finalized, not claimed, mark claimed, emit `WithdrawalClaimed`, return `assetsExpected` (no transfer in queue).
   - `getRequest` and `nextUnfinalized` view helpers.
   - Use `nonReentrant` on `claim` and `finalizeWithdrawals` if queue ever transfers in future.
3. Add `WithdrawalQueue.t.sol` unit tests in `contracts/test/core/WithdrawalQueue.t.sol`.
   - Enqueue monotonic ids, correct storage, totalPendingAssets sum.
   - FIFO finalization with partial liquidity; ensure only earliest requests finalize.
   - Claim only when finalized; double claim revert.
4. Add fuzz tests (same file or separate):
   - Fuzz multiple requests and available liquidity; assert FIFO and `totalPendingAssets` equals sum of unfinalized.
5. Add invariants test `contracts/test/invariants/WithdrawalQueueInvariant.t.sol`.
   - Track ids and verify queue pointers monotonic, no finalized false after claim, totalPendingAssets integrity.

## Test Cases from Issue

- [ ] Requests enqueue with monotonically increasing IDs.
- [ ] Finalization consumes available assets in FIFO order.
- [ ] Claim only succeeds for finalized requests.

## Acceptance Criteria

- [ ] Pending totals equal the sum of unfinalized requests.
- [ ] Events emit correct ids, amounts, and users.

## Verification

```bash
forge test --match-contract WithdrawalQueueTest -vvv
forge test --match-contract WithdrawalQueueInvariantTest -vvv
```

## AI Prompt

Implement Phase 1 WithdrawalQueue contract and tests.
Focus on files:
- contracts/src/interfaces/IWithdrawalQueue.sol
- contracts/src/core/WithdrawalQueue.sol
- contracts/test/core/WithdrawalQueue.t.sol
- contracts/test/invariants/WithdrawalQueueInvariant.t.sol
Requirements:
- UUPS upgradeable, AccessControl roles (DEFAULT_ADMIN_ROLE + CORE_ROLE).
- FIFO queue with nextRequestId, nextPendingId, totalPendingAssets.
- Events: WithdrawalRequested(id,user,shares,assetsExpected,rate), WithdrawalFinalized(id,assets), WithdrawalClaimed(id,user,assetsExpected).
- Functions: requestWithdrawal (CORE_ROLE), finalizeWithdrawals (CORE_ROLE), claim (public), getRequest (view), nextUnfinalized (view).
- Add unit and fuzz tests for FIFO and totals; add invariant test for totalPendingAssets and pointer monotonicity.
Return the exact code changes with tests passing.