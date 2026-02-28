# Phase 2: OllaVault Implementation

## Scope

Create the `OllaVault` contract that implements `IOllaVault`. This is the user-facing ERC-7540/ERC-7575/ERC-4626 vault that:
- Holds AZTEC assets (buffer + finalized unclaimed)
- Mints/burns stAztec shares
- Manages withdrawal request tracking
- Implements all user-facing deposit/redeem/claim flows
- Delegates pricing to OllaCore via cross-contract view calls
- Accepts instructions from OllaCore (CORE_ROLE) for rebalance operations

## Prerequisites

Phase 1 complete — `IOllaVault` and updated `IOllaCore` interfaces exist.

## Implementation Steps

### Step 1: Create OllaVault Contract Scaffold

**File**: `contracts/src/vault/OllaVault.sol`

```solidity
contract OllaVault is
    Initializable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IOllaVault
{
    using SafeERC20 for IERC20;

    // ── CONSTANTS ──
    bytes32 public constant GUARDIAN_ROLE = RolesLib.GUARDIAN_ROLE;
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");
    uint256 public constant BP_DIVISOR = 10_000;
    uint256 public constant MAX_INSTANT_REDEMPTION_FEE_BP = 2_000;

    // ── STATE ──
    VaultModules private _modules;

    // Buffer tracking (moved from OllaCore)
    uint256 private _bufferedAssets;
    uint256 private _finalizedUnclaimedAssets;

    // Withdrawal request tracking (moved from OllaCore)
    mapping(uint256 requestId => address owner) private _requestOwners;
    mapping(address owner => uint256[] requestIds) private _ownerRequestIds;
    mapping(uint256 requestId => uint256 index) private _ownerRequestIndex;

    // ERC-7540 operator approvals (moved from OllaCore)
    mapping(address controller => mapping(address operator => bool approved)) private _operators;

    // Instant redemption fee
    uint256 public instantRedemptionFeeBP;

    // Flow counters (Vault tracks deposits/withdrawals, Core reads them)
    uint256 public cumulativeDeposits;
    uint256 public cumulativeWithdrawals;

    uint256[40] private __gap;
}
```

### Step 2: Implement Initialize

```solidity
function initialize(
    IERC20 asset_,
    IStAztec stAztec_,
    IWithdrawalQueue withdrawalQueue_,
    address safetyModule_,
    address core_,
    address governanceContract_
) external initializer {
    // Validate all addresses non-zero
    __Ownable_init(governanceContract_);
    __AccessControl_init();
    __Pausable_init();
    _pause(); // Start paused like OllaCore does

    _modules = VaultModules({
        asset: asset_,
        stAztec: stAztec_,
        withdrawalQueue: IWithdrawalQueue(withdrawalQueue_),
        safetyModule: safetyModule_,
        core: core_
    });

    instantRedemptionFeeBP = 500; // 5% default

    // Grant roles
    _grantRole(DEFAULT_ADMIN_ROLE, governanceContract_);
    _grantRole(GUARDIAN_ROLE, governanceContract_);
    _grantRole(CORE_ROLE, core_);
}
```

### Step 3: Move Deposit Logic

Extract from `OllaCore._deposit()` → `OllaVault._deposit()`.

Key change: instead of computing shares locally, call `IOllaCore(core).convertToShares(assets)`.

```solidity
function _deposit(address caller, uint256 assets, address receiver) internal returns (uint256 shares) {
    if (receiver == address(0)) revert OllaVault__ZeroAddress("receiver");
    if (assets == 0) revert OllaVault__InvalidAmount();

    VaultModules memory modules = _modules;
    ISafetyModule sm = ISafetyModule(modules.safetyModule);

    if (sm.isPaused()) revert OllaVault__SafetyModulePaused();

    _syncBufferedWithBalance();

    uint256 currentTotalAssets = IOllaCore(modules.core).totalAssets();
    if (!sm.checkDepositAllowed(assets, currentTotalAssets)) {
        revert OllaVault__DepositCapExceeded(assets, currentTotalAssets);
    }

    // Cross-contract call to Core for pricing
    shares = IOllaCore(modules.core).convertToShares(assets);
    modules.asset.safeTransferFrom(caller, address(this), assets);
    _bufferedAssets += assets;
    _syncBufferedWithBalance();
    cumulativeDeposits += assets;

    modules.stAztec.mint(receiver, shares);
    emit Deposit(caller, receiver, assets, shares);
    return shares;
}
```

### Step 4: Move Request Redeem Logic

Extract from `OllaCore._requestRedeem()` → `OllaVault._requestRedeem()`.

Key change: call `IOllaCore(core).convertToAssets(shares)` and `IOllaCore(core).exchangeRate()` for pricing.

```solidity
function _requestRedeem(address owner, uint256 shares, address recipient) internal returns (uint256 requestId) {
    if (recipient == address(0)) revert OllaVault__ZeroAddress("recipient");
    if (shares == 0) revert OllaVault__InvalidAmount();

    VaultModules memory modules = _modules;

    uint256 rate = IOllaCore(modules.core).exchangeRate();
    uint256 assetsExpected = IOllaCore(modules.core).convertToAssets(shares);
    ISafetyModule(modules.safetyModule).checkWithdrawalMinimum(shares);
    uint256 expectedRequestId = modules.withdrawalQueue.nextRequestId();

    _requestOwners[expectedRequestId] = owner;
    _ownerRequestIndex[expectedRequestId] = _ownerRequestIds[owner].length + 1;
    _ownerRequestIds[owner].push(expectedRequestId);
    cumulativeWithdrawals += assetsExpected;

    modules.stAztec.burn(owner, shares);
    requestId = modules.withdrawalQueue.requestWithdrawal(recipient, shares, assetsExpected, rate);
    // ... validation and events (same as current)
}
```

### Step 5: Move Instant Redeem Logic

Extract from `OllaCore._redeem()` → `OllaVault._redeem()`. Same pattern — delegate pricing to Core.

### Step 6: Move Claim Withdrawal Logic

Extract from `OllaCore._claimWithdrawal()` → `OllaVault._claimWithdrawal()`. This is mostly the same but operates on Vault's storage.

### Step 7: Move ERC-7540/ERC-4626/ERC-7575 Surface

All functions currently in `OllaCoreERC7540Ext` move directly into `OllaVault`:
- `share()`, `deposit(assets, receiver)`, `mint(shares, receiver)`
- `withdraw()` (revert), `redeem(shares, receiver, controller)`
- `maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem`
- `previewMint`, `previewWithdraw`, `previewRedeem`
- `setOperator`, `isOperator`
- `requestRedeem(shares, controller, owner)` (ERC-7540 3-arg version)
- `pendingRedeemRequest`, `claimableRedeemRequest`

These no longer need a delegatecall extension since OllaVault is a fresh contract with ample bytecode budget.

### Step 8: Implement CORE_ROLE Functions

These are called by OllaCore during rebalance:

```solidity
/// @notice Core instructs Vault to transfer assets to StakingManager.
function transferToStaking(uint256 amount) external onlyRole(CORE_ROLE) {
    if (amount == 0) revert OllaVault__InvalidAmount();
    if (amount > _bufferedAssets) revert OllaVault__InsufficientBuffer(amount, _bufferedAssets);
    _bufferedAssets -= amount;
    _modules.asset.safeTransfer(address(IOllaCore(_modules.core).stakingManager()), amount);
    emit AssetsTransferredToStaking(amount);
}

/// @notice Core notifies Vault that unstaked assets have been received.
/// @dev Core transfers the assets to Vault before calling this.
function receiveUnstaked(uint256 amount) external onlyRole(CORE_ROLE) {
    _bufferedAssets += amount;
    emit UnstakedAssetsReceived(amount);
}

/// @notice Core instructs Vault to finalize pending withdrawals.
function finalizeWithdrawals(uint256 availableAssets)
    external onlyRole(CORE_ROLE)
    returns (uint256 finalizedAmount, uint256 finalizedCount)
{
    // Same logic as current OllaCore._finalizeWithdrawals()
    // but operating on Vault's _bufferedAssets and _finalizedUnclaimedAssets
}

/// @notice Core instructs Vault to mint fee shares.
function mintFees(
    address treasury, uint256 treasuryShares,
    address provider, uint256 providerShares
) external onlyRole(CORE_ROLE) {
    if (treasuryShares > 0) _modules.stAztec.mint(treasury, treasuryShares);
    if (providerShares > 0) _modules.stAztec.mint(provider, providerShares);
    emit FeesMinted(treasuryShares, providerShares);
}
```

### Step 9: Implement Buffer Reconciliation

Move `_reconcileBufferedAssets` and `_syncBufferedWithBalance` from OllaCore to OllaVault.

### Step 10: ERC-165 Support

```solidity
function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
    return interfaceId == type(IERC7540Redeem).interfaceId
        || interfaceId == type(IERC7540Operator).interfaceId
        || interfaceId == type(IERC7575).interfaceId
        || super.supportsInterface(interfaceId);
}
```

## Function Migration Map

| Current Location | Function | New Location | Notes |
|-----------------|----------|--------------|-------|
| OllaCore | `deposit(assets, recipient, minSharesOut)` | OllaVault | Pricing via Core.convertToShares() |
| OllaCore | `depositWithPermit(...)` | OllaVault | Same |
| OllaCore | `requestRedeem(shares, recipient)` | OllaVault | Pricing via Core.convertToAssets() |
| OllaCore | `requestRedeemWithPermit(...)` | OllaVault | Same |
| OllaCore | `claimRequestById(requestId)` | OllaVault | Direct move |
| OllaCore | `instantRedeem(...)` | OllaVault | Pricing via Core |
| OllaCore | `instantRedeemWithPermit(...)` | OllaVault | Same |
| OllaCore | `_deposit(caller, assets, recipient)` | OllaVault | Core pricing delegation |
| OllaCore | `_requestRedeem(owner, shares, recipient)` | OllaVault | Core pricing delegation |
| OllaCore | `_redeem(owner, shares, recipient)` | OllaVault | Core pricing delegation |
| OllaCore | `_claimWithdrawal(requestId)` | OllaVault | Direct move |
| OllaCore | `_removeOwnerRequest(...)` | OllaVault | Direct move |
| OllaCore | `_reconcileBufferedAssets(...)` | OllaVault | Direct move |
| OllaCore | `_syncBufferedWithBalance()` | OllaVault | Direct move |
| OllaCore | `_increaseBuffered(amount)` | OllaVault | Simplified to `_bufferedAssets +=` |
| OllaCore | `_decreaseBuffered(amount)` | OllaVault | Simplified to `_bufferedAssets -=` |
| OllaCore | `_increaseCumulativeDeposits(amount)` | OllaVault | `cumulativeDeposits +=` |
| OllaCore | `_increaseCumulativeWithdrawals(amount)` | OllaVault | `cumulativeWithdrawals +=` |
| OllaCore | `_finalizedUnclaimedAssets` | OllaVault | Direct move |
| OllaCore | Request tracking mappings | OllaVault | Direct move |
| OllaCore | Operator mappings | OllaVault | Direct move |
| OllaCoreERC7540Ext | All functions | OllaVault | Retire extension |

## Acceptance Criteria

- [ ] OllaVault compiles and implements IOllaVault
- [ ] All user-facing functions (deposit, requestRedeem, claim, instantRedeem + permit variants) work
- [ ] ERC-4626/7575/7540 surface functions implemented
- [ ] CORE_ROLE functions implemented (transferToStaking, receiveUnstaked, finalizeWithdrawals, mintFees)
- [ ] Buffer tracking (bufferedAssets, _finalizedUnclaimedAssets) works correctly
- [ ] Withdrawal request tracking (request owners, indices) works correctly
- [ ] Pricing delegates to Core via external calls
- [ ] No duplicate pricing/conversion logic in Vault

## Verification

```bash
forge build --contracts src/vault/OllaVault.sol
forge test --match-contract OllaVaultTest -vvv
```
