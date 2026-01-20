# WithdrawalQueue Implementation Plan

This plan covers issues #53, #54, #56, #55, #57 for the WithdrawalQueue FIFO system and OllaCore wiring for request, finalize, and claim flows.

## Overview

The WithdrawalQueue locks withdrawals at the request-time exchange rate and finalizes strictly FIFO when liquidity is available. OllaCore burns stAztec on request, finalizes against buffered liquidity, and transfers assets on claim.

**Source of truth**: `research/technical/architecture/components/withdrawal-queue.md`, `research/technical/architecture/flows.md`, `research/technical/architecture/interfaces-and-roles.md`, `research/technical/architecture/invariants.md`.

## Phase Summary

| Phase | Issue | Scope |
| --- | --- | --- |
| [Phase 0](#phase-0-epic-coordination) | #53 | System-level integration and validation |
| [Phase 1](./withdrawal-queue-phase1-contract.md) | #54 | Queue contract, interface, base unit + fuzz tests |
| [Phase 2](./withdrawal-queue-phase2-request.md) | #56 | Burn shares, lock rate, enqueue |
| [Phase 3](./withdrawal-queue-phase3-finalize.md) | #55 | Finalize FIFO, update buffered assets |
| [Phase 4](./withdrawal-queue-phase4-claim.md) | #57 | Claim routing, transfers, paused behavior |

## Phase 0: Epic Coordination (Issue #53)

Issue #53 is the epic tracking the full WithdrawalQueue system. It does not produce a standalone PR; instead it is closed once Phases 1-4 land with the required tests and pause semantics. Track overall acceptance criteria in this file and confirm integration tests cover the full request/finalize/claim flow.

## Architecture Context

- `OllaCore` exposes async entry points (`requestRedeem`, `redeem`) that burn stAztec, compute `assetsExpected`, and call `WithdrawalQueue.requestWithdrawal` (fully replacing synchronous withdrawals). Requests are single-active per user (one outstanding request per address). The receiver is stored at request time, and `redeem` ignores the `shares` input to claim the full finalized request.
- `WithdrawalQueue` maintains FIFO state: `nextRequestId`, `nextPendingId`, `totalPendingAssets`.
- `OllaCore.finalizeWithdrawals` sends available liquidity to `WithdrawalQueue.finalizeWithdrawals` and decrements buffered assets by used amount.
- Users call `WithdrawalQueue.claim` which notifies `OllaCore` to transfer locked assets.

## Files to Create/Modify

| File | Description |
| --- | --- |
| `contracts/src/core/WithdrawalQueue.sol` | UUPS FIFO queue implementation |
| `contracts/src/interfaces/IWithdrawalQueue.sol` | Queue interface and struct |
| `contracts/src/core/OllaCore.sol` | Replace pending-withdrawal path with queue wiring |
| `contracts/src/interfaces/IOllaCore.sol` | Align request/claim APIs and events with queue flow |
| `contracts/test/core/WithdrawalQueue.t.sol` | Queue unit tests + fuzz tests |
| `contracts/test/core/OllaCoreWithdrawalQueue.t.sol` | Core/queue integration tests |
| `contracts/test/invariants/WithdrawalQueueInvariant.t.sol` | Invariant tests for FIFO and totals |

## Verification

```bash
forge test --match-contract WithdrawalQueueTest -vvv
forge test --match-contract OllaCoreWithdrawalQueueTest -vvv
forge test --match-contract WithdrawalQueueInvariantTest -vvv
```

## Notes and Discrepancies

- `OllaCore` currently uses a single pending-withdrawal mapping and `requestRedeem`/`claimPendingWithdraw`. This conflicts with the FIFO queue design in the architecture spec and must be refactored to queue-based flows.
- ERC-7540 naming (`requestRedeem`/`redeem`) differs from the architecture spec (`requestWithdrawal`/`claim`). Plan assumes ERC-7540 external names with queue-backed behavior only.
- Per request, preview helpers (`previewRedeem`, `previewWithdraw`) are removed entirely rather than reverting.
- Assets-based `withdraw` is intentionally omitted; claims are via `redeem` plus a non-standard claim-by-id helper to preserve FIFO request IDs.
- Request IDs are non-zero and unique per request; exchange rate is locked at request time; each user can have only one active request at a time.
- The spec requires requests and claims to be allowed while paused, but finalization blocked. Current `whenNotPaused` modifiers on `requestRedeem`/`claimPendingWithdraw` will block those calls. Plan includes reworking pause checks to match spec.
- Issue details pulled via `gh` for #53, #54, #55, #56, #57.
