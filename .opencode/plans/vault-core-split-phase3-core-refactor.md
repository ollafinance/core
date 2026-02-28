# Phase 3: OllaCore Refactor — Orchestration + Accounting Only

## Scope

Strip all vault/user-facing logic from `OllaCore`, leaving only orchestration (rebalance), accounting, and governance. Update OllaCore to interact with OllaVault via CORE_ROLE calls and view functions.

## Prerequisites

Phase 2 complete — `OllaVault` exists and implements all user-facing logic.

## Implementation Steps

### Step 1: Remove User-Facing Functions from OllaCore

**Delete** the following from `OllaCore.sol`:

External functions:
- `deposit(uint256, address, uint256)`
- `depositWithPermit(...)`
- `requestRedeem(uint256, address)`
- `requestRedeemWithPermit(...)`
- `claimRequestById(uint256)`
- `instantRedeem(...)`
- `instantRedeemWithPermit(...)`
- `setInstantRedemptionFeeBP(uint256)`
- `setERC7540Extension(address)`
- `recoverStAztec(address, uint256)`
- `supportsInterface` (ERC-7540/7575 interface detection — moves to Vault)

View functions to remove:
- `stAztec()` (Vault owns this)
- `withdrawalQueue()` (Vault owns this)
- `requestOwner(uint256)`
- `activeRequestIds(address)`
- `previewDeposit(uint256)` (Vault owns this via Core.convertToShares)
- `previewInstantRedeem(uint256)` (Vault owns this)
- `availableForInstantRedemption()`
- `instantRedemptionFeeBP`

Internal functions to remove:
- `_deposit(caller, assets, recipient)`
- `_requestRedeem(owner, shares, recipient)`
- `_redeem(owner, shares, recipient)`
- `_claimWithdrawal(requestId)`
- `_removeOwnerRequest(owner, requestId)`
- `_reconcileBufferedAssets(recipient)` (moves to Vault)
- `_syncBufferedWithBalance()` (moves to Vault)
- `_increaseBuffered(amount)` / `_decreaseBuffered(amount)` (moves to Vault)
- `_increaseCumulativeDeposits(amount)` / `_increaseCumulativeWithdrawals(amount)` (Vault tracks)
- `_payoutOllaProtocolFees(grossAssetRewards)` — refactored (Core computes fees, calls Vault.mintFees)
- `_calculateProtocolFees(grossAssetRewards)` — keep (Core still computes fee amounts)

State to remove:
- `_finalizedUnclaimedAssets` (moves to Vault)
- `_requestOwners` mapping (moves to Vault)
- `_ownerRequestIds` mapping (moves to Vault)
- `_ownerRequestIndex` mapping (moves to Vault)
- `instantRedemptionFeeBP` (moves to Vault)
- `_operators` mapping (moves to Vault)
- `_erc7540Extension` (retired)

The `fallback()` function (delegatecall to extension) is also removed.

### Step 2: Update Modules Struct

```solidity
struct CoreModules {
    IERC20 asset;
    IOllaVault vault;           // replaces stAztec + withdrawalQueue
    IStakingManager stakingManager;
    IRewardsVault rewardsVault;
    address safetyModule;
}
```

### Step 3: Update `initialize` function

```solidity
function initialize(
    IERC20 asset_,
    IOllaVault vault_,
    IStakingManager stakingManager_,
    uint256 protocolFeeBP_,
    uint256 treasuryFeeSplitBP_,
    address governanceContract_,
    IRewardsVault rewardsVault_,
    address safetyModule_
) external initializer {
    // Note: stAztec, withdrawalQueue removed — accessed via Vault
    // Note: vault_ is new parameter
}
```

### Step 4: Refactor Rebalance to Use Vault

The rebalance state machine structure stays the same, but sub-steps change:

**Harvest** (`_harvestRewards`): Stays the same — interacts with StakingManager + RewardsVault. But rewards vault funds now need to be sent to **Vault** instead of kept by Core.

```solidity
function _pullRewardsVaultFunds() internal returns (uint256 pulledAmount) {
    IRewardsVault rewardsVaultRef = _modules.rewardsVault;
    uint256 rewardsVaultBalance = rewardsVaultRef.balance();
    if (rewardsVaultBalance == 0) return 0;

    // Rewards vault sends funds to Vault (not Core)
    rewardsVaultRef.withdrawTo(address(_modules.vault));
    // Notify Vault to update its buffer
    _modules.vault.receiveUnstaked(rewardsVaultBalance);

    _accountingState.rewardsVaultBalance = 0;
    emit RewardsVaultFundsPulled(rewardsVaultBalance);
    return rewardsVaultBalance;
}
```

**PullUnstaked** (`_pullUnstakedFunds`): StakingManager sends funds to Core, then Core forwards to Vault.

```solidity
function _pullUnstakedFunds() internal returns (uint256 receivedAmount, bool hasRemainingExits) {
    IERC20 assetRef = _modules.asset;
    uint256 balanceBefore = assetRef.balanceOf(address(this));

    uint256 exitAmount;
    (receivedAmount, exitAmount, hasRemainingExits) = _modules.stakingManager.getUnstakedFunds();

    uint256 actualReceived = assetRef.balanceOf(address(this)) - balanceBefore;
    // Forward received funds to Vault
    if (actualReceived > 0) {
        assetRef.safeTransfer(address(_modules.vault), actualReceived);
        _modules.vault.receiveUnstaked(actualReceived);
        emit UnstakedFundsClaimed(actualReceived);
    }

    if (exitAmount > 0) {
        if (exitAmount > _accountingState.stakedPrincipal) {
            exitAmount = _accountingState.stakedPrincipal;
        }
        _accountingState.stakedPrincipal -= exitAmount;
    }
    return (actualReceived, hasRemainingExits);
}
```

**FinalizeWithdrawals** (`_finalizeWithdrawals`): Core instructs Vault to finalize.

```solidity
function _finalizeWithdrawals() internal returns (uint256 finalizedAmount) {
    uint256 available = _modules.vault.bufferedAssets();
    if (available == 0) return 0;

    // Safety module check
    uint256 queued = _modules.vault.pendingWithdrawalAssets();
    uint256 total = totalAssets();
    ISafetyModule(_modules.safetyModule).checkQueueRatio(queued, total);
    if (queued == 0) return 0;

    uint256 finalizedCount;
    (finalizedAmount, finalizedCount) = _modules.vault.finalizeWithdrawals(available);

    emit WithdrawalFinalized(available, finalizedAmount);
    return finalizedAmount;
}
```

**StakeSurplus** (`_stakeSurplus`): Core instructs Vault to transfer assets, then stakes them.

```solidity
function _stakeSurplus(uint256 stakeable) internal returns (uint256 totalStaked) {
    if (stakeable == 0) return 0;

    // Ask Vault to transfer assets to StakingManager
    _modules.vault.transferToStaking(stakeable);

    // Approve and stake via StakingManager
    // Note: assets are now at StakingManager address
    IStakingManager sm = _modules.stakingManager;
    try sm.stake(stakeable) returns (uint256 actualStaked) {
        totalStaked = actualStaked;
    } catch {
        return 0;
    }

    if (totalStaked > 0) {
        _accountingState.stakedPrincipal += totalStaked;
    }
    return totalStaked;
}
```

### Step 5: Refactor Accounting to Read from Vault

`totalAssets()` now reads buffer from Vault:

```solidity
function totalAssets() public view returns (uint256) {
    return _computeTotalAssets(
        _accountingState,
        _modules.vault.bufferedAssets(),
        _modules.vault.pendingWithdrawalAssets()
    );
}

function _computeTotalAssets(
    AccountingState memory buckets,
    uint256 bufferedAssets,
    uint256 pendingWithdrawals
) internal pure returns (uint256 totalAssets_) {
    uint256 total = bufferedAssets
        + buckets.stakedPrincipal
        + buckets.rewardsVaultBalance
        + buckets.claimableRewards;
    if (buckets.slashingDelta >= total) return 0;
    total -= buckets.slashingDelta;
    totalAssets_ = pendingWithdrawals >= total ? 0 : total - pendingWithdrawals;
}
```

Note: `bufferedAssets` is no longer in `_accountingState`. The `AccountingState` struct loses the `bufferedAssets` field.

### Step 6: Refactor Fee Payout

Core computes fees but instructs Vault to mint:

```solidity
function _payoutOllaProtocolFees(uint256 grossAssetRewards)
    internal returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
{
    if (grossAssetRewards == 0 || protocolFeeBP == 0 || totalAssets() == 0) {
        return (0, 0, 0);
    }
    (ollaProtocolFeeAssets, treasuryShares, providerShares) = _calculateProtocolFees(grossAssetRewards);
    emit OllaProtocolFeesPaid(ollaProtocolFeeAssets, treasuryShares, providerShares);

    address treasuryAddr = _treasury();
    address providerRewardsRecipient = _modules.stakingManager.getProviderConfig().rewardsRecipient;

    // Vault mints the shares on Core's instruction
    _modules.vault.mintFees(treasuryAddr, treasuryShares, providerRewardsRecipient, providerShares);

    return (ollaProtocolFeeAssets, treasuryShares, providerShares);
}
```

### Step 7: Update convertToShares / convertToAssets

Core still owns these, but needs stAztec totalSupply. Options:
1. Core reads `vault.stAztec().totalSupply()` (two cross-contract calls)
2. Core stores stAztec address directly for view efficiency

Recommendation: Store `stAztec` address on Core for gas efficiency on this hot path:

```solidity
function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
    return assets.mulDiv(_stAztec.totalSupply() + 1, totalAssets() + 1, rounding);
}
```

This means Core stores `IStAztec _stAztec` alongside the CoreModules, or includes it in the struct.

### Step 8: Refactor Flow Counters

Currently Core tracks `_flowCounters.cumulativeDeposits/Withdrawals`. In the split:
- Vault tracks cumulative deposits/withdrawals (it sees every user operation)
- Core reads them from Vault during `updateAccounting`

Core's `_getFlowsSnapshot()` changes to:

```solidity
function _getFlowsSnapshot() internal view returns (FlowCounters memory snapshot, int256 netFlows) {
    snapshot = FlowCounters({
        cumulativeDeposits: _modules.vault.cumulativeDeposits(),
        cumulativeWithdrawals: _modules.vault.cumulativeWithdrawals(),
        latestReportCumulativeDeposits: _flowCounters.latestReportCumulativeDeposits,
        latestReportCumulativeWithdrawals: _flowCounters.latestReportCumulativeWithdrawals
    });
    (netFlows,,) = _computeNetFlows(snapshot);
}
```

### Step 9: Update Idle Buffer Guard

The `_rebalanceIdleBuffer` check currently compares against `_accountingState.bufferedAssets`. Now it reads from Vault:

```solidity
if (
    _rebalanceIdleBuffer != 0
    && _modules.vault.bufferedAssets() == _rebalanceIdleBuffer
    && !_hasRebalanceWorkAvailable()
) {
    return (0, 0, 0, _modules.vault.bufferedAssets());
}
```

### Step 10: Remove Fallback Function

The `fallback()` function for delegatecall routing to `OllaCoreERC7540Ext` is removed entirely.

## State Migration Summary

| State Variable | Current Owner | New Owner | Migration |
|---------------|--------------|-----------|-----------|
| `_accountingState.bufferedAssets` | OllaCore | OllaVault._bufferedAssets | Vault reads from actual balance on init |
| `_finalizedUnclaimedAssets` | OllaCore | OllaVault | Part of Vault init |
| `_requestOwners` | OllaCore | OllaVault | New Vault starts fresh (or migration) |
| `_ownerRequestIds` | OllaCore | OllaVault | New Vault starts fresh (or migration) |
| `_ownerRequestIndex` | OllaCore | OllaVault | New Vault starts fresh (or migration) |
| `_operators` | OllaCore | OllaVault | New Vault starts fresh |
| `instantRedemptionFeeBP` | OllaCore | OllaVault | Set in Vault init |
| `_erc7540Extension` | OllaCore | Deleted | No longer needed |
| `_rebalanceIdleBuffer` | OllaCore | OllaCore | Stays, reads Vault buffer |
| `_flowCounters` | OllaCore | Split | Vault tracks raw counters, Core tracks report snapshots |

## Acceptance Criteria

- [ ] OllaCore compiles with no user-facing functions
- [ ] Rebalance state machine works via Vault CORE_ROLE calls
- [ ] `totalAssets()` correctly reads buffer from Vault
- [ ] `convertToShares/convertToAssets` works with cross-contract data
- [ ] Fee minting delegates to Vault.mintFees()
- [ ] No duplicate conversion/pricing logic between Core and Vault
- [ ] `OllaCoreERC7540Ext` fallback removed

## Verification

```bash
forge build --contracts src/core/OllaCore.sol
forge test --match-contract OllaCoreTest -vvv
```
