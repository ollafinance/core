# Governance admin propagation and WithdrawalQueue integration

## Current behavior (summary)

- `acceptGovernance()` in `contracts/src/governance/OllaGovernance.sol` calls `_propagateAdminRole(...)` to update admin roles on a set of satellite contracts.
- `_propagateAdminRole` currently builds a list of five satellites and does not include the `WithdrawalQueue` contract.
- `WithdrawalQueue` in `contracts/src/vault/WithdrawalQueue.sol` grants `DEFAULT_ADMIN_ROLE` at initialization and gates UUPS upgrades with `onlyRole(DEFAULT_ADMIN_ROLE)` plus an owner check.
- The withdrawal queue admin is set to the governance contract at deploy time in `contracts/script/Deploy.s.sol`. If admin role propagation during governance rotation does not include the queue, the previous governance address can retain admin capabilities on `WithdrawalQueue`.
- Existing governance transfer tests in `contracts/test/governance/OllaGovernanceTransfer.t.sol` do not currently assert that admin role changes are propagated to `WithdrawalQueue`, so this omission is not caught by regression tests.

## Fix plan

- Update `_propagateAdminRole` in `contracts/src/governance/OllaGovernance.sol`:
  - Fetch the withdrawal queue address via `IOllaVault(vaultAddr).withdrawalQueue()`.
  - Extend the satellites list to include the withdrawal queue, e.g. `[vaultAddr, wq, rv, sm, spr, sfm]`.
  - Preserve the existing `try/catch` behavior for `grantRole` / `revokeRole` so that governance transfer remains non-blocking even if a satellite reverts.
- Add or adjust governance transfer tests in `contracts/test/governance/OllaGovernanceTransfer.t.sol`:
  - Add a regression test that uses `vm.expectCall` to require `grantRole(DEFAULT_ADMIN_ROLE, newGov)` and `revokeRole(DEFAULT_ADMIN_ROLE, oldGov)` to be called on `WithdrawalQueue` during `acceptGovernance()`.
  - Update helper comments and naming that currently imply “5 satellites” so they match the new satellite count.
  - Optionally, add a failure-path test where `WithdrawalQueue` `grantRole` / `revokeRole` reverts and verify that `AdminRolePropagationFailed(withdrawalQueue, ..., isGrant)` is emitted.
- Re-run targeted tests to validate the changes:
  - `forge test --match-contract OllaGovernanceTransferTest`
  - `forge test --match-contract OllaGovernanceEmergencyTest` (sanity check unless emergency scope is expanded)

## Optional follow-up (separate scope)

- Introducing emergency pause coverage for `WithdrawalQueue` is non-trivial because the queue is not pausable today.
- Including the queue in an `emergencyPauseAll` flow would require:
  - Adding pause semantics to relevant state-changing functions in `WithdrawalQueue`.
  - Expanding emergency-related tests to cover queue pause and unpause behavior.
- Recommended default: treat this as a separate design and security improvement, after shipping the minimal, high-confidence fix for admin propagation and regression tests described above.
