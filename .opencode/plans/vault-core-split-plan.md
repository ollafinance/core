# Vault/Core Split Implementation Plan

This plan covers the architectural refactor that separates user-facing vault functionality (OllaVault) from orchestration/accounting (OllaCore), as described in `docs/diagrams-split.md`.

## Overview

The current `OllaCore` is a monolithic contract (~1800 LOC) that combines:
- User-facing vault operations (deposit, redeem, instant redeem, claim)
- ERC-7540/ERC-4626/ERC-7575 compliance (via delegatecall extension)
- Orchestration (rebalance state machine)
- Accounting (totalAssets, exchange rate, fee computation)
- Asset custody (buffered assets, finalized unclaimed assets)
- Share minting/burning authority (stAztec)
- Withdrawal request tracking (owner mappings)
- Governance setters

The split produces two focused contracts:
- **OllaVault**: User-facing ERC-7540/ERC-7575/ERC-4626 vault. Holds assets, mints/burns stAztec, manages withdrawal requests, interacts with SafetyModule for deposit/withdrawal checks.
- **OllaCore**: Orchestration + accounting layer. Manages rebalance, computes totalAssets/exchangeRate, interacts with StakingManager/RewardsVault/SafetyModule. Instructs Vault via CORE_ROLE.

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pricing ownership | Core owns, Vault cross-contract calls | Single source of truth for totalAssets/convertToShares/convertToAssets/exchangeRate. Vault calls Core externally. |
| OllaCoreERC7540Ext | Retire entirely | OllaVault replaces all ERC-4626/7575/7540 surface and operator management. |
| Buffer API | Views + push | Vault exposes `bufferedAssets()` and `pendingWithdrawalAssets()` views. Core also uses push operations (`transferToStaking`, `receiveUnstaked`, `finalizeWithdrawals`) during rebalance. |
| Asset custody | Vault holds all assets | No contract approves another to pull assets. Vault pushes assets on Core instruction. |
| Fee minting | Core instructs Vault | Core computes fees, calls `vault.mintFees(treasury, shares, provider, shares)`. |

## Phase Summary

| Phase | Scope | Description |
|-------|-------|-------------|
| [Phase 1](./vault-core-split-phase1-interfaces.md) | Interface Design | Design IOllaVault, update IOllaCore, define cross-contract boundaries |
| [Phase 2](./vault-core-split-phase2-vault.md) | OllaVault Implementation | Create OllaVault with all user-facing logic extracted from OllaCore |
| [Phase 3](./vault-core-split-phase3-core-refactor.md) | OllaCore Refactor | Strip vault logic from OllaCore, wire up Vault interactions |
| [Phase 4](./vault-core-split-phase4-safety-governance.md) | Safety & Governance Integration | Update SafetyModule, governance, and role model |
| [Phase 5](./vault-core-split-phase5-tests.md) | Test Migration & Gap Filling | Migrate tests, fill gaps, add cross-contract integration tests |
| [Phase 6](./vault-core-split-phase6-cleanup.md) | Cleanup & Deployment | Remove OllaCoreERC7540Ext, deploy scripts, migration path |

## Architecture Context

From `docs/diagrams-split.md`:

```
Vault (user-facing)              Core (orchestration)
+---------------------------+    +---------------------------+
| OllaVault (ERC-7540)      |    | OllaCore                  |
| - deposit / mint          |    | - rebalance()             |
| - requestRedeem           |    | - updateAccounting()      |
| - claimRedeem             |    | - totalAssets()           |
| - instantRedeem           |    | - convertToShares/Assets  |
| - setOperator / isOperator|    | - exchangeRate()          |
| - bufferedAssets (state)  |<-->| - stakedPrincipal (state) |
| - pendingWithdrawalAssets |    | - rewardsVaultBalance     |
| - _finalizedUnclaimed     |    | - claimableRewards        |
| - MINTER/BURNER on stAztec|    | - slashingDelta           |
| - WithdrawalQueue CORE_ROLE|   | - fee computation         |
+---------------------------+    +---------------------------+
         |                                |
         v                                v
    [StAztec]                    [StakingManager]
    [WithdrawalQueue]            [RewardsVault]
    [SafetyModule]               [SafetyModule]
```

Cross-contract calls:
- **Vault → Core** (view): `totalAssets()`, `convertToShares()`, `convertToAssets()`, `exchangeRate()`
- **Core → Vault** (view): `bufferedAssets()`, `pendingWithdrawalAssets()`
- **Core → Vault** (CORE_ROLE): `transferToStaking(amount)`, `receiveUnstaked(amount)`, `finalizeWithdrawals(available)`, `mintFees(treasury, shares, provider, shares)`
- **Vault → Core** (none): Vault never writes to Core

## Files to Create/Modify

### New Files

| File | Description |
|------|-------------|
| `contracts/src/vault/OllaVault.sol` | ERC-7540 vault implementation |
| `contracts/src/vault/interfaces/IOllaVault.sol` | Vault interface |
| `contracts/test/vault/OllaVault*.t.sol` | Vault unit tests |
| `contracts/test/integration/VaultCoreIntegration.t.sol` | Cross-contract integration tests |

### Modified Files

| File | Description |
|------|-------------|
| `contracts/src/core/OllaCore.sol` | Remove vault logic, add Vault interaction |
| `contracts/src/core/interfaces/IOllaCore.sol` | Remove vault functions, add accounting views |
| `contracts/src/safetymodule/ISafetyModule.sol` | May need VAULT reference alongside CORE |
| `contracts/src/safetymodule/SafetyModule.sol` | Update authorized callers |
| `contracts/src/safetymodule/MockSafetyModule.sol` | Update for new architecture |
| `contracts/src/core/libraries/GovernanceLib.sol` | Split governance between Vault and Core |
| `contracts/test/core/olla-core/*.t.sol` | Migrate to test new architecture |

### Deleted Files

| File | Reason |
|------|--------|
| `contracts/src/core/OllaCoreERC7540Ext.sol` | Replaced entirely by OllaVault |
| `contracts/test/core/olla-core/OllaCoreERC7540.t.sol` | Replaced by OllaVault tests |
| `contracts/test/core/olla-core/OllaCoreERC4626Surface.t.sol` | Replaced by OllaVault tests |

## Invariants That Must Hold Post-Split

1. **No functional regression**: Every user action (deposit, requestRedeem, claim, instantRedeem) must produce identical economic outcomes.
2. **Accounting identity**: `totalAssets = vault.bufferedAssets + core.stakedPrincipal + core.rewardsVaultBalance + core.claimableRewards - core.slashingDelta - vault.pendingWithdrawalAssets`
3. **Asset safety**: Only Vault holds user assets. Core never holds user assets directly (except during staking transfers where approval is given per-call).
4. **Exchange rate continuity**: Exchange rate computation remains identical (`(totalAssets+1) * 1e18 / (totalSupply+1)`).
5. **Rebalance correctness**: The rebalance state machine must produce identical state transitions.
6. **Fee parity**: Protocol fee computation and distribution must be identical.

## Verification

```bash
# Run all tests
forge test -vvv

# Run specific test suites
forge test --match-contract OllaVaultTest -vvv
forge test --match-contract OllaCoreTest -vvv
forge test --match-contract VaultCoreIntegrationTest -vvv

# Coverage
forge coverage --match-contract "OllaVault|OllaCore"

# Check bytecode sizes
forge build --sizes
```
