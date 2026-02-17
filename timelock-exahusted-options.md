# Timelock Exhausted Options

This document summarizes all considered timelock approaches and why Option A was selected for Olla.

## Option A — OpenZeppelin TimelockController (Selected)

**Summary:** Use a standard OZ `TimelockController` as the `DEFAULT_ADMIN_ROLE` holder for all contracts. Governance actions are scheduled and executed after a fixed delay.

**Pros**
- Battle-tested and audited implementation
- No contract code changes required
- Simple operational workflow
- Supports batched actions and cancellation

**Cons**
- Single delay value for all actions
- Requires governance ops to adapt to schedule/execute flow

**Why selected:** Best security uplift per unit of complexity, minimal re-audit scope, and compatible with current contract code.

---

## Option B — Tiered Timelocks (Multiple Delays)

**Summary:** Deploy multiple TimelockControllers (e.g., short/medium/long) and assign different roles per severity of action.

**Pros**
- Delay matches risk level (upgrades slower, parameter tweaks faster)
- Can preserve faster operational changes

**Cons**
- Requires contract modifications (new role checks)
- Higher governance complexity
- More contracts to audit and configure

**Why not selected:** Adds significant code changes and operational complexity; best deferred to later.

---

## Option C — Custom Two-Step Timelock Per Function

**Summary:** Add `proposeX()` and `acceptX()` for each governance parameter, enforcing an internal delay.

**Pros**
- Per-parameter delay granularity
- Fully self-contained, no external timelock dependency

**Cons**
- High code churn and storage overhead
- Large re-audit surface
- Easy to introduce errors

**Why not selected:** Reinvents TimelockController with higher risk and development effort.

---

## Option D — Multisig-Only Governance (No Timelock)

**Summary:** Rely exclusively on multisig for governance security.

**Pros**
- Simplest setup
- No additional contracts

**Cons**
- No user exit window
- Does not mitigate compromised multisig
- Fails common audit expectations

**Why not selected:** Does not meet security or audit standards.
