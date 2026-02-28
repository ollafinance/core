# Phase 5: Test Migration & Gap Filling

## Scope

Migrate all existing OllaCore tests to the split architecture, fill test gaps for new contract boundaries, and add cross-contract integration tests. **No functionality regression** — every test that passes today must have an equivalent in the new architecture.

## Prerequisites

Phases 1-4 complete — OllaVault, refactored OllaCore, and role model are wired up.

## Test File Migration Map

### Tests Moving to OllaVault

| Current Test File | New Test File | Notes |
|-------------------|--------------|-------|
| `OllaCoreDeposit.t.sol` | `test/vault/OllaVaultDeposit.t.sol` | Deposit tests move to Vault |
| `OllaCoreWithdrawal.t.sol` | `test/vault/OllaVaultWithdrawal.t.sol` | Withdrawal request + claim tests |
| `OllaCoreInstantRedemption.t.sol` | `test/vault/OllaVaultInstantRedemption.t.sol` | Instant redeem tests |
| `OllaCoreSlippage.t.sol` | `test/vault/OllaVaultSlippage.t.sol` | Slippage protection tests |
| `OllaCoreERC7540.t.sol` | `test/vault/OllaVaultERC7540.t.sol` | ERC-7540 operator/async tests |
| `OllaCoreERC4626Surface.t.sol` | `test/vault/OllaVaultERC4626Surface.t.sol` | ERC-4626 surface tests |
| `OllaCoreFirstDepositorAttack.t.sol` | `test/vault/OllaVaultFirstDepositorAttack.t.sol` | Inflation attack tests |
| `OllaCoreRecoverStAztec.t.sol` | `test/vault/OllaVaultRecoverStAztec.t.sol` | Recovery tests |
| `OllaCoreReconcile.t.sol` | `test/vault/OllaVaultReconcile.t.sol` | Reconciliation tests |
| `OllaCoreRemoveOwnerRequest.t.sol` | `test/vault/OllaVaultRemoveOwnerRequest.t.sol` | Request tracking tests |
| `OllaCoreRequestRedeemZeroCheck.t.sol` | `test/vault/OllaVaultRequestRedeemZeroCheck.t.sol` | Zero check tests |
| `OllaCore.reentrancy.t.sol` | Split: Vault + Core reentrancy | Reentrancy tests for both |

### Tests Staying on OllaCore

| Current Test File | Status | Notes |
|-------------------|--------|-------|
| `OllaCoreRebalance.t.sol` | **Stays, updated** | Rebalance tests updated for Vault interaction |
| `OllaCoreRebalanceFuzz.t.sol` | **Stays, updated** | Fuzz tests for rebalance |
| `OllaCoreRebalancePause.t.sol` | **Stays, updated** | Pause interaction during rebalance |
| `OllaCoreRebalanceStuck.t.sol` | **Stays, updated** | Stuck rebalance recovery |
| `OllaCoreRebalanceIdleGuard.t.sol` | **Stays, updated** | Idle guard reads Vault buffer |
| `OllaCoreRebalanceInfiniteRestart.t.sol` | **Stays, updated** | Infinite restart prevention |
| `OllaCoreRebalanceFinalizeDeadlock.t.sol` | **Stays, updated** | Deadlock prevention |
| `OllaCoreAccounting.t.sol` | **Stays, updated** | Accounting reads from Vault |
| `OllaCoreProtocolFees.t.sol` | **Stays, updated** | Fee computation + Vault.mintFees |
| `OllaCorePermissionlessRebalance.t.sol` | **Stays, updated** | Cooldown + permissionless access |
| `OllaCoreAccessControl.t.sol` | **Split** | Core keeps governance tests, Vault gets user-facing access tests |
| `OllaCoreInit.t.sol` | **Split** | Both Vault and Core need init tests |
| `OllaCoreBoundsValidation.t.sol` | **Split** | Fee bounds in Vault, other bounds in Core |
| `OllaCore.upgrade.t.sol` | **Split** | Both contracts are UUPS upgradeable |
| `OllaCore.invariant.t.sol` | **Updated** | Invariant handler updated for both contracts |

### New Test Files

| Test File | Description |
|-----------|-------------|
| `test/integration/VaultCoreIntegration.t.sol` | End-to-end flows spanning Vault ↔ Core |
| `test/vault/OllaVaultCoreRole.t.sol` | CORE_ROLE function access control |
| `test/vault/OllaVaultInit.t.sol` | Vault initialization tests |
| `test/vault/OllaVaultAccessControl.t.sol` | Vault role-based access control |
| `test/vault/OllaVaultUpgrade.t.sol` | Vault UUPS upgrade tests |
| `test/vault/OllaVault.reentrancy.t.sol` | Vault reentrancy protection |
| `test/vault/OllaVault.invariant.t.sol` | Vault invariant tests |
| `test/core/olla-core/OllaCoreVaultInteraction.t.sol` | Core ↔ Vault interaction tests |

## Implementation Steps

### Step 1: Create Shared Test Helpers

**File**: `test/helpers/VaultCoreTestSetup.sol`

A base contract that deploys both OllaVault and OllaCore with all dependencies:

```solidity
abstract contract VaultCoreTestSetup is Test {
    OllaVault vault;
    OllaCore core;
    MockAztec asset;
    StAztec stAztec;
    MockWithdrawalQueue withdrawalQueue;
    MockSafetyModule safetyModule;
    MockStakingManager stakingManager;
    MockRewardsVault rewardsVault;
    OllaGovernance governance;

    function setUp() public virtual {
        // Deploy all contracts
        // Wire up roles
        // Fund test accounts
    }
}
```

### Step 2: Integration Test — Full Deposit-Rebalance-Withdraw Cycle

```solidity
contract VaultCoreIntegrationTest is VaultCoreTestSetup {
    function test_fullCycle_depositRebalanceWithdraw() public {
        // 1. User deposits via Vault
        // 2. Rebalance stakes via Core → Vault.transferToStaking
        // 3. Accounting update via Core (reads Vault state)
        // 4. User requests redeem via Vault
        // 5. Rebalance unstakes + finalizes via Core → Vault
        // 6. User claims via Vault
    }

    function test_crossContractPricing() public {
        // Vault.deposit calls Core.convertToShares
        // Verify shares match expected
    }

    function test_feeMinting_coreInstructsVault() public {
        // Simulate rewards
        // Core.updateAccounting → Vault.mintFees
        // Verify stAztec minted to treasury and provider
    }

    function test_rebalance_vaultBufferInteraction() public {
        // Deposit creates buffer in Vault
        // Core reads vault.bufferedAssets()
        // Core instructs Vault.transferToStaking()
        // Verify buffer decreased
    }
}
```

### Step 3: Test CORE_ROLE Access Control

```solidity
contract OllaVaultCoreRoleTest is VaultCoreTestSetup {
    function test_transferToStaking_onlyCoreRole() public {
        vm.expectRevert(); // AccessControl error
        vm.prank(address(0xdead));
        vault.transferToStaking(100);
    }

    function test_receiveUnstaked_onlyCoreRole() public { ... }
    function test_finalizeWithdrawals_onlyCoreRole() public { ... }
    function test_mintFees_onlyCoreRole() public { ... }

    function test_transferToStaking_fromCore_succeeds() public {
        vm.prank(address(core));
        vault.transferToStaking(100);
    }
}
```

### Step 4: Test Cross-Contract View Consistency

```solidity
contract CrossContractViewTest is VaultCoreTestSetup {
    function test_totalAssets_consistency() public {
        // Vault.totalAssets() delegates to Core.totalAssets()
        // Both should return the same value
        assertEq(vault.totalAssets(), core.totalAssets());
    }

    function test_convertToShares_fromVault_matchesCore() public {
        uint256 fromVault = vault.convertToShares(1e18);
        uint256 fromCore = core.convertToShares(1e18);
        assertEq(fromVault, fromCore);
    }

    function test_exchangeRate_consistency() public {
        // After deposit, exchange rate should be consistent
    }
}
```

### Step 5: Migrate Existing Tests

For each test file being migrated:
1. Copy the test file to the new location
2. Update the base contract to use `VaultCoreTestSetup`
3. Replace `core.deposit(...)` with `vault.deposit(...)`
4. Replace `core.requestRedeem(...)` with `vault.requestRedeem(...)`
5. Replace `core.instantRedeem(...)` with `vault.instantRedeem(...)`
6. Update event expectations (events may come from Vault now)
7. Ensure all assertions still pass

### Step 6: Update Invariant Tests

The invariant handler needs to operate on both contracts:

```solidity
contract VaultCoreInvariantHandler {
    // User actions → Vault
    function deposit(uint256 assets) external { vault.deposit(...); }
    function requestRedeem(uint256 shares) external { vault.requestRedeem(...); }

    // Permissionless actions → Core
    function rebalance() external { core.rebalance(); }
    function updateAccounting() external { core.updateAccounting(); }
}

// Invariants:
// 1. vault.bufferedAssets + core.stakedPrincipal + ... = core.totalAssets + pending
// 2. stAztec.totalSupply * exchangeRate ≈ core.totalAssets
// 3. vault balance >= vault.bufferedAssets + vault._finalizedUnclaimed
```

### Step 7: Reentrancy Tests for Both Contracts

Separate reentrancy test suites:
- Vault: malicious stAztec, malicious asset, malicious WithdrawalQueue
- Core: malicious StakingManager, malicious RewardsVault, malicious Vault

### Step 8: Fill Test Gaps

New test scenarios that didn't exist before:
- Core calls Vault when Vault is paused (should revert)
- Vault calls Core when Core is paused (pricing still works — view functions)
- Race condition: user deposits during rebalance (Vault buffer changes mid-rebalance)
- Core.transferToStaking with amount > Vault buffer (should revert)
- Fee minting with zero amounts
- Vault receives direct asset transfers (reconciliation)
- Circular pricing: Vault calls Core.convertToShares which calls Vault.bufferedAssets

## Acceptance Criteria

- [ ] All existing test scenarios have equivalents in the new architecture
- [ ] `forge test` passes with 100% of current test cases covered
- [ ] New cross-contract integration tests pass
- [ ] CORE_ROLE access control tested
- [ ] Reentrancy tests for both Vault and Core
- [ ] Invariant tests updated for split architecture
- [ ] No test duplication — each test exercises the owning contract

## Verification

```bash
# Run all tests
forge test -vvv

# Run with coverage
forge coverage

# Verify no test regression
forge test --match-contract "OllaVault|OllaCore|VaultCore" -vvv --gas-report
```
