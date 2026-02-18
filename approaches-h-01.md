# H-01 Approaches: Two-Step Governance Transfer

## Problem
`setGovernance()` is atomic and irreversible. A wrong address or compromised key irreversibly transfers all governance roles. A timelock adds delay but does not add the accept/confirm step.

## Constraints
- Contracts are not deployed yet; storage layout changes are acceptable.
- UUPS proxies are in use; keep upgrade safety in mind for future deployments.
- Roles are currently granted/revoked via AccessControl.

## Goals
- Prevent governance lockout above all else.
- Require explicit acceptance by the new governance address.
- Minimize code complexity; extra operational calls are acceptable.
- Keep timelock integration compatible.

## Approach A: Propose + Accept + Explicit Finalize (Safest)
Split transfer into three explicit steps to eliminate any lockout risk.

**Design**
- New state: `pendingGovernance` and `previousGovernance` (optional if you store old value).
- `proposeGovernance(address)` sets `pendingGovernance` and emits an event.
- `acceptGovernance()` callable only by `pendingGovernance`.
- In `acceptGovernance()`, grant roles to the new governance but do not revoke the old.
- `finalizeGovernanceTransfer()` revokes roles from the old governance and clears `pendingGovernance`.
- `cancelGovernanceProposal()` allowed by current governance while pending.

**Pros**
- Eliminates lockout by ensuring at least one governance always retains roles.
- Acceptance proves the new address controls its key.
- Works well with a timelock (proposal scheduled, accept called by new governance).

**Cons**
- Requires three transactions (proposal, accept, finalize).
- Slightly more operational steps, but minimal code complexity.

**Timelock interaction**
- Timelock schedules `proposeGovernance(newGov)`.
- New governance calls `acceptGovernance()` after proposal executes.
- Timelock schedules `finalizeGovernanceTransfer()` after acceptance.
- If wrong address, acceptance never happens; old governance remains.

## Approach B: Timelock-Only Proposal
Same as Approach A, but only the timelock can propose.

**Design**
- Only the timelock can call `proposeGovernance()`.
- Acceptance still requires `msg.sender == pendingGovernance`.
- Finalization remains timelock-controlled.

**Pros**
- Prevents direct proposal by the current governance; all proposals delayed.
- Aligns with audit expectation of timelocked sensitive actions.

**Cons**
- Requires timelock ownership for all upgrades/proposals.
- Higher operational overhead (every change needs a scheduled call).

## Approach C: Two-Step Only (No Finalize)
Classic propose + accept without an explicit finalize step.

**Design**
- `proposeGovernance(newGov)` sets pending.
- `acceptGovernance()` grants roles to new governance and revokes old in the same call.

**Pros**
- Simple; only two calls.
- Still requires acceptance by new governance.

**Cons**
- Still risks lockout if the old governance is revoked and the new governance is wrong.
- Less safe than Approach A under the stated priority.

## Approach D: EIP-712 Signed Acceptance
Use a signature to confirm acceptance without a direct transaction from the new governance.

**Design**
- `proposeGovernance(newGov, signature)` verifies EIP-712 acceptance.
- Optionally keep `acceptGovernance()` for direct confirmation.

**Pros**
- Allows off-chain confirmation with on-chain execution by timelock.
- Avoids requiring the new governance to send a transaction if desired.

**Cons**
- Extra complexity and signature validation surface.
- Adds cryptographic verification code that is unnecessary for the primary goal.

## Migration Notes
- Preserve grant-before-revoke order in any function that revokes roles.
- Emit explicit events for propose/accept/finalize.
- Since contracts are not deployed, add storage freely but keep a gap for future upgrades.

## Suggested Implementation Path
Approach A is the safest under the stated priority: no lockout even if a wrong address is proposed. It keeps code simple (no signatures) and uses extra operational calls instead of extra logic.
