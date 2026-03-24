You’re right to flag this. I checked the current code, and this issue is still present.

- acceptGovernance() still calls \_propagateAdminRole(...) in contracts/src/governance/OllaGovernance.sol:126 and contracts/src/governance/OllaGovernance.sol:142.
- \_propagateAdminRole still builds a 5-item satellite list in contracts/src/governance/OllaGovernance.sol:346 and does not include WithdrawalQueue.
- WithdrawalQueue still grants DEFAULT_ADMIN_ROLE at init (contracts/src/vault/WithdrawalQueue.sol:124) and gates UUPS upgrades with onlyRole(DEFAULT_ADMIN_ROLE) plus owner check (contracts/src/vault/WithdrawalQueue.sol:307).
- The queue admin is set to governance at deploy (contracts/script/Deploy.s.sol:180, contracts/script/Deploy.s.sol:596), so missing propagation during rotation leaves stale admin risk exactly as described.
  I also ran current governance transfer tests (forge test --match-contract OllaGovernanceTransferTest), and they all pass, which confirms there is currently no regression test that would fail on this omission.
  Fix plan
- Update \_propagateAdminRole in contracts/src/governance/OllaGovernance.sol:
  - Fetch queue address via IOllaVault(vaultAddr).withdrawalQueue().
  - Extend satellites from 5 to 6: [vaultAddr, wq, rv, sm, spr, sfm].
  - Keep existing try/catch behavior for grant/revoke so transfer remains non-blocking.
- Add/adjust governance transfer tests in contracts/test/governance/OllaGovernanceTransfer.t.sol:
  - Add a regression test that uses vm.expectCall to require grantRole(DEFAULT_ADMIN_ROLE, newGov) and revokeRole(DEFAULT_ADMIN_ROLE, oldGov) are called on withdrawalQueue during acceptGovernance().
  - Update helper comments/naming that currently imply “5 satellites” so they match post-fix reality.
  - (Optional but useful) add one failure-path test where queue grantRole/revokeRole reverts and verify AdminRolePropagationFailed(withdrawalQueue, ..., isGrant) is emitted.
- Re-run targeted tests:
  - forge test --match-contract OllaGovernanceTransferTest
  - forge test --match-contract OllaGovernanceEmergencyTest (sanity check only unless emergency scope is expanded)
    Optional follow-up (separate scope)
- The emergency-pause recommendation is non-trivial because WithdrawalQueue is not pausable today. Including it in emergencyPauseAll requires adding pause semantics to queue state-changing functions, then expanding emergency tests.
  Recommended default: ship the minimal, high-confidence fix now (admin propagation + regression tests), and track emergency queue pausing as a separate design/security ticket.
  One question before implementation: do you want me to do only the minimal propagation fix now (recommended), or also include the larger WithdrawalQueue pausable/emergency integration in the same change?
