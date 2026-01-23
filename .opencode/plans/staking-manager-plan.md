# StakingManager Final Touches Plan

This plan covers the remaining hardening work for `contracts/src/core/StakingManager.sol`:

- Proper access control (roles, admin boundaries, upgrade auth).
- Reentrancy safety (explicitly reviewed and tested).
- Upgradeability (UUPS), following patterns in `contracts/src/core/OllaCore.sol`.

## Phase Summary

| Phase | Doc | Scope |
| --- | --- | --- |
| Phase 0 | `./staking-manager-phase0-baseline.md` | Threat model, trust assumptions, invariants, test gaps |
| Phase 1 | `./staking-manager-phase1-upgradeability.md` | Convert to UUPS upgradeable + proxy-based tests |
| Phase 2 | `./staking-manager-phase2-access-control.md` | Role admin model + provider admin rotation decisions |
| Phase 3 | `./staking-manager-phase3-reentrancy.md` | Reentrancy matrix + malicious-mock tests |
| Phase 4 | `./staking-manager-phase4-storage-layout.md` | Storage layout lock, gaps, upgrade regression |
| Phase 5 | `./staking-manager-phase5-tests.md` | Coverage completion + regression gates |

## Out Of Scope (for this plan)

- Changes to Aztec rollup contracts (`contracts/dependencies/...`).
- New protocol features (only correctness/safety hardening).
