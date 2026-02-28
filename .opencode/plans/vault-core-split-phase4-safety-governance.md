# Phase 4: Safety Module, Governance & Role Model Integration

## Scope

Update SafetyModule, governance contracts, and role model to work with the split architecture. Ensure the CORE_ROLE pattern is correctly wired and that SafetyModule can be called by both Vault and Core as needed.

## Prerequisites

Phase 2 and Phase 3 complete — OllaVault and refactored OllaCore both exist and compile.

## Implementation Steps

### Step 1: Update SafetyModule for Dual Callers

Currently, SafetyModule has a single `CORE` address that authorizes calls to `setLatestAccountingTimestamp`. In the split:

- **Core** calls: `checkRateDrop`, `checkQueueRatio`, `checkAccountingLiveness`, `setLatestAccountingTimestamp`
- **Vault** calls: `checkDepositAllowed` (view — no auth needed), `checkWithdrawalMinimum` (view — no auth needed), `isPaused` (view)

Since the Vault only calls view functions on SafetyModule, no auth changes are needed for Vault. The `CORE()` address continues to point to OllaCore.

**However**, if SafetyModule validation of `CORE` is checked in `setSafetyModule` on OllaCore (via GovernanceLib), this still works because Core's address is what SafetyModule.CORE() returns.

For Vault's `setSafetyModule`, we need a separate validation — the Vault's safety module doesn't need `CORE()` to match Vault (Vault only calls view functions). But we should consider whether Vault should validate the safety module address differently.

**File**: `contracts/src/safetymodule/ISafetyModule.sol` — No changes needed.

**File**: `contracts/src/safetymodule/SafetyModule.sol` — No changes needed. The CORE address stays as OllaCore.

**File**: `contracts/src/safetymodule/MockSafetyModule.sol` — Update constructor/init to work with test setup.

### Step 2: Update GovernanceLib

Split governance functions between Vault and Core.

**Decision: WithdrawalQueue `setGasThreshold` ownership** → **Governance calls WithdrawalQueue directly**.

Currently, `Core.setRebalanceGasThreshold(t)` atomically propagates `t` to both `StakingManager` and `WithdrawalQueue` via `GovernanceLib.propagateGasThreshold()`. In the split, Core no longer has authority over WithdrawalQueue (Vault is its `core`), so this propagation breaks.

The cleanest resolution is to separate the two:
- `Core.setRebalanceGasThreshold(t)` propagates to **StakingManager only** (Core still owns it)
- Governance calls `WithdrawalQueue.setGasThreshold(t)` **directly** via `DEFAULT_ADMIN_ROLE` (which governance already holds on WithdrawalQueue)

**Rationale**: Core shouldn't reach into Vault's sub-components — that violates the split boundary. The atomicity concern (updating both in one tx) is fully addressed by OllaGovernance's timelock batching: both calls are bundled into a single timelock proposal (one vote, one execution). This also opens the door to independent threshold tuning if the finalization loop and staking loop turn out to need different gas budgets.

**Required change on WithdrawalQueue**: Change `setGasThreshold` from `onlyCore` to `onlyRole(DEFAULT_ADMIN_ROLE)`:

```solidity
// Before:
function setGasThreshold(uint256 threshold) external override onlyCore { ... }

// After:
function setGasThreshold(uint256 threshold) external override onlyRole(DEFAULT_ADMIN_ROLE) { ... }
```

Governance already holds `DEFAULT_ADMIN_ROLE` on WithdrawalQueue (granted in `WithdrawalQueue.initialize`), so no new role grants are needed.

**Updated GovernanceLib** — remove WithdrawalQueue propagation:

```solidity
library GovernanceLib {
    function setSafetyModule(CoreModules storage modules, address newSafetyModule)
        external returns (address oldSafetyModule)
    {
        // Same validation — SafetyModule.CORE() must match address(this) (= OllaCore)
    }

    function propagateGasThreshold(CoreModules storage modules, uint256 newThreshold) external {
        modules.stakingManager.setGasThreshold(newThreshold);
        // WithdrawalQueue gas threshold is set separately by governance via DEFAULT_ADMIN_ROLE
    }
}
```

**Governance usage pattern** (single timelock proposal):
```solidity
// In a single timelock batch:
core.setRebalanceGasThreshold(newThreshold);      // updates Core + StakingManager
withdrawalQueue.setGasThreshold(newThreshold);     // updates WithdrawalQueue
```

### Step 3: Wire Up Role Model

From the diagrams, the role model is:

**StAztec Roles**:
- `MINTER_ROLE` → OllaVault (was OllaCore)
- `BURNER_ROLE` → OllaVault (was OllaCore)

**OllaVault Roles**:
- `CORE_ROLE` → OllaCore
- `GUARDIAN_ROLE` → Guardian
- `owner` → OllaGovernance

**OllaCore Roles**:
- `GUARDIAN_ROLE` → Guardian
- `OPERATOR_ROLE` → Olla Operator
- `owner` → OllaGovernance
- Permissionless: `rebalance()`, `updateAccounting()`

**WithdrawalQueue Roles**:
- `CORE_ROLE` → OllaVault (was OllaCore) — Vault now owns withdrawal queue interaction
- `DEFAULT_ADMIN_ROLE` → OllaGovernance

**SafetyModule**:
- `CORE` → OllaCore (unchanged — only Core calls state-changing safety functions)
- `GUARDIAN_ROLE` → Guardian
- `DEFAULT_ADMIN_ROLE` → OllaGovernance

### Step 4: Update WithdrawalQueue CORE_ROLE

Currently, WithdrawalQueue's `CORE_ROLE` is set to OllaCore's address. In the split, the Vault manages withdrawals, so:

**WithdrawalQueue.CORE_ROLE → OllaVault**

This means Vault calls `withdrawalQueue.requestWithdrawal()`, `withdrawalQueue.finalizeWithdrawals()`, `withdrawalQueue.claimWithdrawal()`.

However, during rebalance, Core instructs Vault to finalize. The call chain is:
```
Core.rebalance() → Vault.finalizeWithdrawals(available) → WithdrawalQueue.finalizeWithdrawals(available)
```

This is correct — Vault is the intermediary.

### Step 5: Vault Governance Functions

OllaVault needs its own governance functions:

```solidity
// Guardian
function pause() external onlyRole(GUARDIAN_ROLE);
function unpause() external onlyRole(GUARDIAN_ROLE);

// Owner (Governance)
function setInstantRedemptionFeeBP(uint256 newFeeBP) external onlyOwner;
function setSafetyModule(address newSafetyModule) external onlyOwner;
function reconcileBufferedAssets() external onlyOwner returns (uint256 delta);
function recoverStAztec(address recipient, uint256 amount) external onlyOwner;
```

### Step 6: OllaGovernance Treasury Access

Currently, Core accesses treasury via `IOllaGovernance(owner()).treasury()`. In the split:
- Core still needs treasury for fee computation → `_treasury()` stays in Core
- Vault needs treasury for instant redemption fee transfer → Vault also needs `_treasury()`

Both contracts have `owner()` set to OllaGovernance, so both can call `IOllaGovernance(owner()).treasury()`.

### Step 7: Deployment Order

The deployment must handle circular references:
1. Deploy StAztec
2. Deploy WithdrawalQueue
3. Deploy SafetyModule
4. Deploy StakingManager
5. Deploy RewardsVault
6. Deploy OllaCore (needs Vault address — use placeholder or two-step init)
7. Deploy OllaVault (needs Core address)
8. Configure OllaCore with Vault address (if two-step)
9. Grant roles:
   - StAztec: MINTER_ROLE + BURNER_ROLE → OllaVault
   - WithdrawalQueue: CORE_ROLE → OllaVault
   - OllaVault: CORE_ROLE → OllaCore
   - SafetyModule: CORE → OllaCore (set in constructor)

**Circular dependency resolution**: Core needs Vault address, Vault needs Core address. Options:
- Two-step initialization: Deploy both, then call `setVault()` on Core and `setCore()` on Vault
- Deploy Core first with address(0) vault, deploy Vault with Core address, then `core.setVault(vault)`
- Use CREATE2 to predict addresses

Recommendation: Two-step init — add a `setVault(address)` function on Core (owner-only, callable once).

## Acceptance Criteria

- [ ] SafetyModule works with split architecture (CORE = OllaCore)
- [ ] StAztec MINTER/BURNER roles point to OllaVault
- [ ] WithdrawalQueue CORE_ROLE points to OllaVault
- [ ] WithdrawalQueue `setGasThreshold` changed from `onlyCore` to `onlyRole(DEFAULT_ADMIN_ROLE)`
- [ ] OllaVault has CORE_ROLE granted to OllaCore
- [ ] GovernanceLib propagates gas threshold to StakingManager only (not WithdrawalQueue)
- [ ] Both Vault and Core can access treasury via governance
- [ ] Deployment order documented and circular dependency resolved

## Verification

```bash
forge test --match-contract SafetyModuleTest -vvv
forge test --match-contract OllaVaultAccessControlTest -vvv
forge test --match-contract OllaCoreAccessControlTest -vvv
```
