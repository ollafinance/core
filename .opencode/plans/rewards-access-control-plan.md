# Rewards Access Control Implementation Plan

This plan covers issue #51 for implementing rewards access control in OllaCore.

## Overview

Add access control for rewards configuration and parameter updates. The issue focuses on restricting updates to fee parameters (`protocolFeeBP`, `treasuryFeeSplitBP`) and recipient addresses, with proper validation and event emission.

**Source of truth**: Current contract implementations in `contracts/src/core/OllaCore.sol` and research docs in `research/technical/architecture/`.

## Issue Requirements

From issue #51:

### Scope
- Restrict updates to `_protocolFeeBP`, `_treasuryFeeSplitBP`, and recipient addresses
- Validate parameter ranges and non-zero addresses
- Emit update events for all parameter changes

### Tests Required
- [ ] Unauthorized updates revert
- [ ] Invalid values revert  
- [ ] Update events include old/new values

### Acceptance Criteria
- [ ] All privileged configuration is permissioned and observable

## Phase Summary

| Phase | Issue | Scope |
|-------|-------|-------|
| [Phase 1](./rewards-access-control-phase1-implementation.md) | #51 | Core implementation with setters, validation, events, and tests |

## Current State Analysis

### OllaCore.sol (Lines 68-69)
```solidity
uint256 private _protocolFeeBP;
uint256 private _treasuryFeeSplitBP;
```

### Current Initialization (Lines 148-149)
```solidity
_protocolFeeBP = protocolFeeBP_;
_treasuryFeeSplitBP = treasuryFeeSplitBP_;
```

### Validation in `_validateIntialilParams` (Lines 741-746)
```solidity
if (protocolFeeBP_ > BP_DIVISOR) {
    revert OllaCore__InvalidAmount();
}
if (treasuryFeeSplitBP_ > BP_DIVISOR) {
    revert OllaCore__InvalidAmount();
}
```

### Existing Roles
- `DEFAULT_ADMIN_ROLE` - Governance (manages roles and upgrades)
- `GUARDIAN_ROLE` - Governance (pause/unpause)
- `OPERATOR_ROLE` - Protocol operator (rebalance, updateAccounting)
- `CORE_ROLE` - Self-role for module callbacks

### Research Spec Reference (interfaces-and-roles.md)
Per the spec, `DEFAULT_ADMIN_ROLE` (GuardianMultisig) should manage all roles and upgrades. Fee parameter updates should be governance-restricted.

## Architecture Context

```
┌─────────────────────────────────────────────────────────────┐
│                        OllaCore                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Fee Configuration (Governance-restricted)            │    │
│  │  - _protocolFeeBP (0-10000 BP)                      │    │
│  │  - _treasuryFeeSplitBP (0-10000 BP)                 │    │
│  │  - governance address (fee recipient)               │    │
│  │  - rewardsVault address (provider fee recipient)    │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Fee Distribution (during updateAccounting)           │    │
│  │  1. Calculate grossRewards                          │    │
│  │  2. protocolFeeAssets = grossRewards * feeBP / 10000│    │
│  │  3. Split into treasuryShares + providerShares      │    │
│  │  4. Mint shares to governance + rewardsVault        │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `contracts/src/core/OllaCore.sol` | Modify | Add setter functions, events, validation |
| `contracts/src/core/interfaces/IOllaCore.sol` | Modify | Add events and function signatures |
| `contracts/test/core/OllaCore.t.sol` | Modify | Add comprehensive tests |

## Implementation Summary

### New Events (in IOllaCore.sol)
```solidity
event ProtocolFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);
event TreasuryFeeSplitUpdated(uint256 oldSplitBP, uint256 newSplitBP);
event GovernanceUpdated(address oldGovernance, address newGovernance);
event RewardsVaultUpdated(address oldRewardsVault, address newRewardsVault);
```

### New Errors (in IOllaCore.sol)
```solidity
error OllaCore__InvalidFeeBP(uint256 feeBP);
error OllaCore__InvalidSplitBP(uint256 splitBP);
```

### New Functions (in OllaCore.sol)
```solidity
function setProtocolFeeBP(uint256 newFeeBP) external onlyRole(DEFAULT_ADMIN_ROLE);
function setTreasuryFeeSplitBP(uint256 newSplitBP) external onlyRole(DEFAULT_ADMIN_ROLE);
function setGovernance(address newGovernance) external onlyRole(DEFAULT_ADMIN_ROLE);
function setRewardsVault(address newRewardsVault) external onlyRole(DEFAULT_ADMIN_ROLE);

// View functions
function protocolFeeBP() external view returns (uint256);
function treasuryFeeSplitBP() external view returns (uint256);
```

## Verification

```bash
# Run all OllaCore tests
forge test --match-contract OllaCore -vvv

# Run specific fee tests
forge test --match-test "test.*Fee" -vvv
forge test --match-test "test.*RewardsAccessControl" -vvv

# Check coverage
forge coverage --match-contract OllaCore
```

## Notes

1. **Role Selection**: Using `DEFAULT_ADMIN_ROLE` for fee updates aligns with the research spec where governance manages critical protocol parameters.

2. **Validation**: Fee values must be ≤ BP_DIVISOR (10000) to prevent invalid percentages.

3. **Address Updates**: Both `governance` and `rewardsVault` are recipients of fee shares, so updating them requires careful access control.

4. **Event Design**: Events include both old and new values per issue requirements for observability.
