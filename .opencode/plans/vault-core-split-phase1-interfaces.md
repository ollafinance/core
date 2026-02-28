# Phase 1: Interface Design & Cross-Contract Boundaries

## Scope

Design the new `IOllaVault` interface, update `IOllaCore` to reflect the orchestration-only role, and define the exact function signatures and access patterns for cross-contract communication.

## Prerequisites

None — this is the foundation phase.

## Implementation Steps

### Step 1: Create `IOllaVault` Interface

**File**: `contracts/src/vault/interfaces/IOllaVault.sol`

This interface defines the user-facing vault surface. It combines:
- Custom Olla deposit/redeem functions (with slippage protection, permit variants)
- ERC-7540 async redeem (operator management, requestRedeem with controller separation)
- ERC-4626/ERC-7575 surface (deposit, mint, redeem, withdraw, maxDeposit, etc.)
- CORE_ROLE functions that only OllaCore can call
- Governance functions owned by the Vault

```solidity
interface IOllaVault {
    // ── STRUCTS ──

    struct VaultModules {
        IERC20 asset;
        IStAztec stAztec;
        IWithdrawalQueue withdrawalQueue;
        address safetyModule;
        address core; // IOllaCore reference for pricing
    }

    // ── EVENTS ──
    // Move from IOllaCore: Deposit, WithdrawalRequested, WithdrawalClaimed,
    //   WithdrawalFinalized, InstantRedemption, InstantRedemptionFeeUpdated,
    //   OperatorSet, RedeemRequest, BufferedAssetsReconciled, StAztecRecovered,
    //   ERC7540ExtensionUpdated (removed - no extension needed)

    // New events:
    event AssetsTransferredToStaking(uint256 amount);
    event UnstakedAssetsReceived(uint256 amount);
    event FeesMinted(uint256 treasuryShares, uint256 providerShares);

    // ── ERRORS ──
    // Move relevant errors from IOllaCore

    // ── USER-FACING FUNCTIONS ──

    /// @notice Deposits assets and mints stAztec shares (Olla-native with slippage).
    function deposit(uint256 assets, address recipient, uint256 minSharesOut)
        external returns (uint256 shares);

    /// @notice Deposits with permit signature.
    function depositWithPermit(
        uint256 assets, address recipient, uint256 minSharesOut,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint256 shares);

    /// @notice Requests async redemption (Olla-native).
    function requestRedeem(uint256 shares, address recipient)
        external returns (uint256 requestId);

    /// @notice Requests async redemption with permit.
    function requestRedeemWithPermit(
        uint256 shares, address recipient,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint256 requestId);

    /// @notice Claims a finalized withdrawal request.
    function claimRequestById(uint256 requestId)
        external returns (uint256 assets);

    /// @notice Instant redemption with fee.
    function instantRedeem(uint256 shares, address recipient, uint256 minAssetsOut)
        external returns (uint256 assetsAfterFee);

    /// @notice Instant redemption with permit.
    function instantRedeemWithPermit(
        uint256 shares, address recipient, uint256 minAssetsOut,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint256 assetsAfterFee);

    // ── ERC-4626/ERC-7575 SURFACE ──

    function asset() external view returns (address);
    function share() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxMint(address) external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
    function maxRedeem(address controller) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    // ── ERC-7540 OPERATOR + ASYNC ──

    function setOperator(address operator, bool approved) external returns (bool);
    function isOperator(address controller, address operator) external view returns (bool);
    function requestRedeem(uint256 shares, address controller, address owner)
        external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller)
        external view returns (uint256);
    function claimableRedeemRequest(uint256 requestId, address controller)
        external view returns (uint256);

    // ── CORE_ROLE FUNCTIONS (only callable by OllaCore) ──

    /// @notice Transfers buffered assets to staking (Core instructs Vault to push).
    function transferToStaking(uint256 amount) external;

    /// @notice Receives unstaked assets returned from staking.
    /// @dev Core calls this after pulling funds from StakingManager.
    function receiveUnstaked(uint256 amount) external;

    /// @notice Finalizes pending withdrawal requests using available liquidity.
    /// @param availableAssets Max assets to use for finalization.
    /// @return finalizedAmount Actual assets used.
    /// @return finalizedCount Number of requests finalized.
    function finalizeWithdrawals(uint256 availableAssets)
        external returns (uint256 finalizedAmount, uint256 finalizedCount);

    /// @notice Mints fee shares to treasury and provider.
    function mintFees(
        address treasury, uint256 treasuryShares,
        address provider, uint256 providerShares
    ) external;

    // ── VAULT STATE VIEWS (for Core accounting) ──

    /// @notice Returns current buffered (liquid) assets held by the Vault.
    function bufferedAssets() external view returns (uint256);

    /// @notice Returns current pending withdrawal assets.
    function pendingWithdrawalAssets() external view returns (uint256);

    // ── GUARDIAN FUNCTIONS ──

    function pause() external;
    function unpause() external;

    // ── GOVERNANCE FUNCTIONS ──

    function setInstantRedemptionFeeBP(uint256 newFeeBP) external;
    function setSafetyModule(address newSafetyModule) external;
    function reconcileBufferedAssets() external returns (uint256 delta);
    function recoverStAztec(address recipient, uint256 amount) external;

    // ── VAULT VIEW FUNCTIONS ──

    function withdrawalQueue() external view returns (address);
    function safetyModule() external view returns (address);
    function stAztec() external view returns (address);
    function instantRedemptionFeeBP() external view returns (uint256);
    function availableForInstantRedemption() external view returns (uint256);
    function previewInstantRedeem(uint256 shares) external view returns (uint256);
    function requestOwner(uint256 requestId) external view returns (address);
    function activeRequestIds(address owner) external view returns (uint256[] memory);
}
```

### Step 2: Update `IOllaCore` Interface

**File**: `contracts/src/core/interfaces/IOllaCore.sol`

Remove all user-facing functions. Core becomes orchestration + accounting only.

Functions to **remove** from IOllaCore:
- `deposit`, `depositWithPermit`
- `requestRedeem`, `requestRedeemWithPermit`
- `claimRequestById`
- `instantRedeem`, `instantRedeemWithPermit`
- `setInstantRedemptionFeeBP`
- `setERC7540Extension`
- `recoverStAztec`
- `requestOwner`, `activeRequestIds`
- `previewDeposit`, `previewInstantRedeem`, `availableForInstantRedemption`
- `instantRedemptionFeeBP`
- `stAztec` (moves to Vault)
- `withdrawalQueue` (moves to Vault)
- Operator-related events

Functions to **keep** on IOllaCore:
- `initialize` (updated params — takes `vault` reference instead of `stAztec`/`withdrawalQueue`)
- `rebalance()`
- `updateAccounting()`
- `totalAssets()`, `convertToShares()`, `convertToAssets()`, `exchangeRate()`
- `accountingState()`, `latestReport()`, `flowCounters()`, `rebalanceProgress()`
- `protocolFeeBP`, `treasuryFeeSplitBP`, `targetBufferedAssets`, `rebalanceGasThreshold`, `rebalanceCooldown`
- `setProtocolFeeBP`, `setTreasuryFeeSplitBP`, `setTargetBufferedAssets`, `setRebalanceGasThreshold`, `setRebalanceCooldown`
- `setSafetyModule` (Core still interacts with SafetyModule for accounting checks)
- `reconcileBufferedAssets` → removed (Vault owns this now)
- `forceRebalanceReset`
- `pause`, `unpause`

Functions to **add** to IOllaCore:
- `vault() external view returns (address)` — returns the OllaVault address
- `asset() external view` — keep for convenience (delegates or stores)

### Step 3: Define Modules Structs

**OllaVault.VaultModules**:
```solidity
struct VaultModules {
    IERC20 asset;
    IStAztec stAztec;
    IWithdrawalQueue withdrawalQueue;
    address safetyModule;
    address core; // for pricing cross-contract calls
}
```

**OllaCore.CoreModules** (updated from current Modules):
```solidity
struct CoreModules {
    IERC20 asset;
    address vault; // IOllaVault
    IStakingManager stakingManager;
    IRewardsVault rewardsVault;
    address safetyModule;
}
```

Note: Core no longer holds `stAztec`, `withdrawalQueue` directly — those are accessed through Vault.

## Acceptance Criteria

- [ ] `IOllaVault` interface compiles and covers all user-facing + CORE_ROLE + view functions
- [ ] `IOllaCore` interface compiles with vault functions removed and `vault()` accessor added
- [ ] Both interfaces have NatSpec documentation
- [ ] No circular import dependencies
- [ ] Modules structs are updated for both contracts
- [ ] Cross-contract call boundaries are clearly documented

## Open Questions for Phase 2

1. Should `OllaVault` be UUPS upgradeable like `OllaCore`?  (Most likely yes)
2. Storage layout: should the Vault use the same storage gap pattern?
3. Should `IOllaCore.totalAssets()` read from Vault, or should Vault read from Core?
   → **Answer**: Core owns totalAssets computation. Core reads `vault.bufferedAssets()` and `vault.pendingWithdrawalAssets()` as inputs. Vault's `totalAssets()` ERC-4626 function proxies to `core.totalAssets()`.

## Verification

```bash
# Compile interfaces only
forge build --contracts src/vault/interfaces/IOllaVault.sol
forge build --contracts src/core/interfaces/IOllaCore.sol
```
