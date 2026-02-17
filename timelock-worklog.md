# Timelock Worklog

## 2026-02-17

- Added deployment and ops scripts for Option A timelock rollout:
  - `contracts/script/ops/DeployTimelock.s.sol`
  - `contracts/script/ops/TransferAdminToTimelock.s.sol`
  - `contracts/script/ops/SetGovernanceToTimelock.s.sol`
- Scripts support env overrides for timelock addresses and role holders.
- Ran `yarn forge:fmt`.
- Ran `yarn lint` (solhint warnings only, no errors; see tool output file for details).
- Added README timelock usage notes and updated mermaid diagram to show timelock admin flow.
- Ran `yarn deploy:local --quiet && yarn dev:mock-loop:until-error`; mock loop was terminated after timeout (~4 minutes) as instructed (no errors before timeout).
