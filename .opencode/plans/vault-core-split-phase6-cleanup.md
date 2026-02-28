# Phase 6: Cleanup, Deletion & Deployment

## Scope

Remove deprecated files (OllaCoreERC7540Ext), clean up imports, finalize deployment scripts, and document the migration path.

## Prerequisites

Phases 1-5 complete — all contracts work, all tests pass.

## Implementation Steps

### Step 1: Delete Deprecated Files

| File | Reason |
|------|--------|
| `contracts/src/core/OllaCoreERC7540Ext.sol` | Replaced entirely by OllaVault |
| `contracts/test/core/olla-core/OllaCoreERC7540.t.sol` | Replaced by Vault ERC-7540 tests |
| `contracts/test/core/olla-core/OllaCoreERC4626Surface.t.sol` | Replaced by Vault ERC-4626 tests |

### Step 2: Clean Up OllaCore

Remove leftover state variables that were migrated to Vault:
- Remove `_finalizedUnclaimedAssets`
- Remove `_requestOwners` mapping
- Remove `_ownerRequestIds` mapping
- Remove `_ownerRequestIndex` mapping
- Remove `instantRedemptionFeeBP`
- Remove `_operators` mapping
- Remove `_erc7540Extension`
- Update `__gap` size to account for removed slots

Remove `bufferedAssets` from `AccountingState` struct. This is a breaking change for the struct — update all references.

### Step 3: Clean Up Imports

Remove unused imports from OllaCore:
- `IERC20Permit` (Vault handles permits now)
- `IERC7540Operator`, `IERC7540Redeem` (Vault implements these)
- `IERC7575` (Vault implements this)
- `IERC165` (Vault handles supportsInterface)

### Step 4: Update GovernanceLib

Remove `recoverStAztec` from GovernanceLib (moved to Vault's own governance).
Update `setSafetyModule` if needed for the new Modules struct.

### Step 5: Update MockSafetyModule and MaliciousSafetyModule

Ensure test mocks work with the split architecture. The `CORE()` address should still return OllaCore's address.

### Step 6: Update Foundry Config

If needed, update `contracts/foundry.toml` remappings for the new `vault/` source directory.

Add to `foundry.toml`:
```toml
[profile.default]
src = "src"
# Ensure vault/ directory is included in compilation
```

### Step 7: Create Deployment Script

**File**: `contracts/script/DeployVaultCore.s.sol`

```solidity
contract DeployVaultCore is Script {
    function run() external {
        // 1. Deploy StAztec
        // 2. Deploy WithdrawalQueue
        // 3. Deploy SafetyModule (CORE = predicted OllaCore address)
        // 4. Deploy StakingManager
        // 5. Deploy RewardsVault
        // 6. Deploy OllaCore proxy (vault = address(0) initially)
        // 7. Deploy OllaVault proxy (core = OllaCore address)
        // 8. Core.setVault(OllaVault address)
        // 9. Grant roles:
        //    - StAztec: MINTER + BURNER → OllaVault
        //    - WithdrawalQueue: CORE_ROLE → OllaVault
        //    - OllaVault: CORE_ROLE → OllaCore
        // 10. Unpause both contracts
    }
}
```

### Step 8: Bytecode Size Check

The split should reduce individual contract sizes significantly:
- Current OllaCore: ~24KB (near EIP-170 limit, hence the extension)
- Expected OllaVault: ~12-16KB
- Expected OllaCore: ~12-16KB

Verify with:
```bash
forge build --sizes 2>&1 | grep -E "OllaVault|OllaCore"
```

### Step 9: Update Documentation

Update `docs/diagrams-split.md`:
- Mark as "implemented" or move to main architecture docs
- Update any references to the old monolithic OllaCore

### Step 10: Gas Comparison

Run gas benchmarks to measure the impact of cross-contract calls:
- `vault.deposit()` now calls `core.convertToShares()` externally
- `core.totalAssets()` now calls `vault.bufferedAssets()` + `vault.pendingWithdrawalAssets()` externally
- `core.rebalance()` makes multiple calls to Vault

Document any significant gas increases.

## Acceptance Criteria

- [ ] No deprecated files remain
- [ ] OllaCore and OllaVault compile independently
- [ ] Both contracts are under EIP-170 bytecode limit
- [ ] All tests pass: `forge test`
- [ ] Deployment script works end-to-end
- [ ] Gas report shows acceptable overhead from cross-contract calls
- [ ] No orphaned imports or dead code
- [ ] Storage gap sizes are correct

## Verification

```bash
# Full test suite
forge test -vvv

# Bytecode sizes
forge build --sizes

# Gas report
forge test --gas-report

# Coverage
forge coverage
```
