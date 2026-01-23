# Phase 2: Deposit Cap Integration

**Issue**: #71 - feat: Deposit cap integration

## Scope

- Enforce SafetyModule deposit cap checks in `OllaCore.deposit`.

## Prerequisites

- Phase 1 SafetyModule contract and interface available.

## Implementation Steps

1. Import `ISafetyModule` in `contracts/src/core/OllaCore.sol` and store typed handle for `_safetyModule`.
2. In `OllaCore.deposit`, call `checkDepositAllowed(assets, totalAssets())` before share calculation to match `flows.md`.
3. Revert when the check returns false (add a dedicated error in `OllaCore` or reuse an existing error pattern).
4. Update `contracts/src/interfaces/IOllaCore.sol` only if any new error or event is surfaced.
5. Add tests in `contracts/test/core/OllaCoreSafetyModule.t.sol`:
   - Deposit above cap reverts.
   - Deposit at cap succeeds.
   - `checkDepositAllowed` uses `totalAssets()` to calculate against current TVL.

## Test Cases from Issue

- [ ] Deposit above cap reverts.
- [ ] Deposit at cap succeeds.

## Acceptance Criteria

- [ ] Deposit cap is enforced deterministically.

## Verification

```bash
forge test --match-contract OllaCoreSafetyModule -vvv
```
