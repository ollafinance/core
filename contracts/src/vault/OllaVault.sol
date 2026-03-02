// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC7540Operator, IERC7540Redeem } from "@forge-std/interfaces/IERC7540.sol";
import { IERC7575 } from "@forge-std/interfaces/IERC7575.sol";
import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Ownable2StepUpgradeable } from "@oz-upgradeable/access/Ownable2StepUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { RolesLib } from "src/shared/RolesLib.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

/// @title OllaVault
/// @notice User-facing ERC-7540/ERC-7575/ERC-4626 vault.
/// @dev Holds assets, mints/burns stAztec, manages withdrawal requests.
///      Pricing is delegated to OllaCore via cross-contract view calls.
/// @author Olla Core contributors
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

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for guardian pause/unpause actions.
    bytes32 public constant GUARDIAN_ROLE = RolesLib.GUARDIAN_ROLE;

    /// @notice Role that only OllaCore holds — for rebalance instructions.
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    /// @notice Basis points divisor.
    uint256 public constant BP_DIVISOR = 10_000;

    /// @notice Maximum instant redemption fee: 20%.
    uint256 public constant MAX_INSTANT_REDEMPTION_FEE_BP = 2_000;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract related interfaces and addresses.
    VaultModules private _modules;

    /// @notice Buffer tracking — liquid assets held by the vault.
    uint256 private _bufferedAssets;

    /// @notice Assets that have been finalized but not yet claimed.
    uint256 private _finalizedUnclaimedAssets;

    /// @notice Withdrawal request tracking.
    mapping(uint256 requestId => address owner) private _requestOwners;
    mapping(address owner => uint256[] requestIds) private _ownerRequestIds;
    mapping(uint256 requestId => uint256 index) private _ownerRequestIndex;

    /// @notice ERC-7540 operator approvals: controller -> operator -> approved.
    mapping(address controller => mapping(address operator => bool approved)) private _operators;

    /// @notice The instant redemption fee in basis points (0-10000).
    uint256 public instantRedemptionFeeBP;

    /// @notice Cumulative deposits tracked for Core accounting.
    uint256 public cumulativeDeposits;

    /// @notice Cumulative withdrawals tracked for Core accounting.
    uint256 public cumulativeWithdrawals;

    /// @notice Storage gap for upgradability.
    // slither-disable-next-line unused-state
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a finalization exceeds available buffered assets.
    error OllaVault__InsufficientBufferedAssets(uint256 amount, uint256 available);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaVault
    function initialize(
        IERC20 asset_,
        IStAztec stAztec_,
        address withdrawalQueue_,
        address safetyModule_,
        address core_,
        address governanceContract_
    ) external override initializer {
        if (address(asset_) == address(0)) revert OllaVault__ZeroAddress("asset_");
        if (address(stAztec_) == address(0)) revert OllaVault__ZeroAddress("stAztec_");
        if (withdrawalQueue_ == address(0)) revert OllaVault__ZeroAddress("withdrawalQueue_");
        if (safetyModule_ == address(0)) revert OllaVault__ZeroAddress("safetyModule_");
        if (core_ == address(0)) revert OllaVault__ZeroAddress("core_");
        if (governanceContract_ == address(0)) revert OllaVault__ZeroAddress("governanceContract_");

        __Ownable_init(governanceContract_);
        __AccessControl_init();
        __Pausable_init();
        _pause();

        _modules = VaultModules({
            asset: asset_,
            stAztec: stAztec_,
            withdrawalQueue: IWithdrawalQueue(withdrawalQueue_),
            safetyModule: safetyModule_,
            core: core_
        });

        instantRedemptionFeeBP = 500; // 5% default

        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, governanceContract_);
        _grantRole(GUARDIAN_ROLE, governanceContract_);
        _grantRole(CORE_ROLE, core_);
    }

    /// @inheritdoc IOllaVault
    function deposit(uint256 assets, address recipient, uint256 minSharesOut)
        external
        override(IOllaVault)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        shares = _deposit(msg.sender, assets, recipient);
        // slither-disable-next-line timestamp
        if (shares < minSharesOut) revert OllaVault__SlippageExceeded(shares, minSharesOut);
        return shares;
    }

    /// @inheritdoc IOllaVault
    function depositWithPermit(
        uint256 assets,
        address recipient,
        uint256 minSharesOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant whenNotPaused returns (uint256 shares) {
        // slither-disable-next-line reentrancy-benign
        IERC20Permit(address(_modules.asset)).permit(msg.sender, address(this), assets, deadline, v, r, s);
        shares = _deposit(msg.sender, assets, recipient);
        // slither-disable-next-line timestamp
        if (shares < minSharesOut) revert OllaVault__SlippageExceeded(shares, minSharesOut);
        return shares;
    }

    /// @inheritdoc IOllaVault
    function requestRedeemWithPermit(uint256 shares, address controller, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (controller == address(0)) revert OllaVault__ZeroAddress("controller");
        // slither-disable-next-line reentrancy-benign
        _modules.stAztec.permit(msg.sender, address(this), shares, deadline, v, r, s);
        requestId = _executeRedeemRequest(msg.sender, controller, controller, shares);
        return requestId;
    }

    /// @inheritdoc IOllaVault
    function claimRequestById(uint256 requestId) external override nonReentrant whenNotPaused returns (uint256 assets) {
        if (_ownerRequestIndex[requestId] == 0) revert OllaVault__RequestNotFound(requestId);
        _checkControllerOrOperator(_requestOwners[requestId]);
        assets = _claimWithdrawal(requestId, address(0));
        return assets;
    }

    /// @inheritdoc IOllaVault
    function instantRedeem(uint256 shares, address recipient, uint256 minAssetsOut)
        external
        override(IOllaVault)
        nonReentrant
        whenNotPaused
        returns (uint256 assetsAfterFee)
    {
        return _instantRedeem(shares, recipient, minAssetsOut);
    }

    /// @inheritdoc IOllaVault
    function instantRedeemWithPermit(
        uint256 shares,
        address recipient,
        uint256 minAssetsOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant whenNotPaused returns (uint256 assetsAfterFee) {
        // slither-disable-next-line reentrancy-benign
        _modules.stAztec.permit(msg.sender, address(this), shares, deadline, v, r, s);
        return _instantRedeem(shares, recipient, minAssetsOut);
    }

    function _instantRedeem(uint256 shares, address recipient, uint256 minAssetsOut)
        private
        returns (uint256 assetsAfterFee)
    {
        assetsAfterFee = _redeem(msg.sender, shares, recipient);
        // slither-disable-next-line timestamp
        if (assetsAfterFee < minAssetsOut) revert OllaVault__SlippageExceeded(assetsAfterFee, minAssetsOut);
        return assetsAfterFee;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-4626/7575 SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits assets and mints shares to receiver (ERC-4626).
    /// @dev This standard overload has NO slippage protection. Prefer the 3-arg
    ///      `deposit(assets, receiver, minSharesOut)` variant for front-run safety.
    function deposit(uint256 assets, address receiver)
        external
        override(IOllaVault)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        shares = _deposit(msg.sender, assets, receiver);
        return shares;
    }

    /// @notice Mints exact shares to receiver by depositing assets (ERC-4626).
    function mint(uint256 shares, address receiver)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert OllaVault__ZeroAddress("receiver");
        if (shares == 0) revert OllaVault__InvalidAmount();
        assets = IOllaCore(_modules.core).convertToAssetsCeil(shares);
        _deposit(msg.sender, assets, receiver);
        return assets;
    }

    /// @notice Claims a finalized async redeem request (ERC-4626/ERC-7540).
    function redeem(uint256 shares, address receiver, address controller)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        _checkControllerOrOperator(controller);
        if (receiver == address(0)) revert OllaVault__ZeroAddress("receiver");
        uint256 requestId = _findClaimableRequest(controller, shares);
        assets = _claimWithdrawal(requestId, receiver);
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                    ERC-7540 OPERATOR + ASYNC REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets or removes an operator for the caller (ERC-7540).
    function setOperator(address operator, bool approved) external override whenNotPaused returns (bool) {
        if (operator == msg.sender) revert OllaVault__InvalidParameter();
        _operators[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @notice Requests an async redemption (ERC-7540).
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        override(IOllaVault)
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (msg.sender != owner && !_operators[owner][msg.sender]) {
            revert OllaVault__Unauthorized();
        }
        if (controller == address(0)) revert OllaVault__ZeroAddress("controller");

        uint256 assets = IOllaCore(_modules.core).convertToAssets(shares);
        requestId = _executeRedeemRequest(owner, controller, controller, shares);

        emit RedeemRequest(controller, owner, requestId, msg.sender, assets);
        return requestId;
    }

    /*//////////////////////////////////////////////////////////////
                        CORE_ROLE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaVault
    function transferToCore(uint256 amount) external override onlyRole(CORE_ROLE) {
        if (amount == 0) revert OllaVault__InvalidAmount();
        uint256 buffered = _bufferedAssets;
        if (amount > buffered) revert OllaVault__InsufficientBuffer(amount, buffered);
        _bufferedAssets = buffered - amount;
        _modules.asset.safeTransfer(msg.sender, amount);
        emit AssetsTransferredToStaking(amount);
    }

    /// @inheritdoc IOllaVault
    /// @dev Callers MUST `safeTransfer` exactly `amount` to this contract before
    ///      calling this function. Fee-on-transfer tokens are not supported.
    function receiveUnstaked(uint256 amount) external override onlyRole(CORE_ROLE) {
        _bufferedAssets += amount;

        // Defense-in-depth: verify the real balance backs the updated accounting.
        uint256 actual = _modules.asset.balanceOf(address(this));
        uint256 required = _finalizedUnclaimedAssets + _bufferedAssets;
        if (actual < required) {
            revert OllaVault__BufferedBalanceMismatch(_bufferedAssets, actual - _finalizedUnclaimedAssets);
        }

        emit UnstakedAssetsReceived(amount);
    }

    /// @inheritdoc IOllaVault
    // solhint-disable-next-line function-max-lines
    // slither-disable-next-line reentrancy-events
    function finalizeWithdrawals(uint256 availableAssets)
        external
        override
        onlyRole(CORE_ROLE)
        returns (uint256 finalizedAmount, uint256 finalizedCount)
    {
        // slither-disable-next-line timestamp,incorrect-equality
        if (availableAssets == 0) return (0, 0);

        IWithdrawalQueue queue = _modules.withdrawalQueue;
        uint256 queued = queue.totalPendingAssets();
        // slither-disable-next-line timestamp,incorrect-equality
        if (queued == 0) return (0, 0);

        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
        (finalizedAmount, finalizedCount) = queue.finalizeWithdrawals(availableAssets);

        uint256 queuedAfter = queue.totalPendingAssets();
        if (queued - queuedAfter != finalizedAmount) {
            revert OllaVault__FinalizeAmountMismatch(queued - queuedAfter, finalizedAmount);
        }

        uint256 buffered = _bufferedAssets;
        if (finalizedAmount > buffered) {
            revert OllaVault__InsufficientBufferedAssets(finalizedAmount, buffered);
        }

        // slither-disable-next-line incorrect-equality
        if ((finalizedAmount == 0) != (finalizedCount == 0)) {
            revert OllaVault__FinalizeInconsistent(finalizedAmount, finalizedCount);
        }

        // slither-disable-next-line incorrect-equality
        if (finalizedAmount == 0) return (0, 0);

        _bufferedAssets = buffered - finalizedAmount;
        _finalizedUnclaimedAssets += finalizedAmount;

        // slither-disable-next-line reentrancy-events
        // CORE_ROLE only; external call to trusted WithdrawalQueue.
        emit WithdrawalFinalized(availableAssets, finalizedAmount);
        return (finalizedAmount, finalizedCount);
    }

    /// @inheritdoc IOllaVault
    // slither-disable-next-line reentrancy-events
    function mintFees(address treasury, uint256 treasuryShares, address provider, uint256 providerShares)
        external
        override
        onlyRole(CORE_ROLE)
    {
        IStAztec stAztecRef = _modules.stAztec;
        // CORE_ROLE only; stAztec.mint() is a trusted internal token.
        if (treasuryShares > 0) stAztecRef.mint(treasury, treasuryShares);
        if (providerShares > 0) stAztecRef.mint(provider, providerShares);
        emit FeesMinted(treasuryShares, providerShares);
    }

    /*//////////////////////////////////////////////////////////////
                      PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses the vault.
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        _pause();
        emit Paused();
    }

    /// @notice Unpauses the vault.
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        _unpause();
        emit Unpaused();
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaVault
    function setInstantRedemptionFeeBP(uint256 newFeeBP) external override onlyOwner whenNotPaused {
        if (newFeeBP > MAX_INSTANT_REDEMPTION_FEE_BP) revert OllaVault__InvalidFeeBP(newFeeBP);
        uint256 oldFeeBP = instantRedemptionFeeBP;
        instantRedemptionFeeBP = newFeeBP;
        emit InstantRedemptionFeeUpdated(oldFeeBP, newFeeBP);
    }

    /// @inheritdoc IOllaVault
    function setSafetyModule(address newSafetyModule) external override onlyOwner whenNotPaused {
        if (newSafetyModule == address(0)) revert OllaVault__ZeroAddress("newSafetyModule");
        address oldSafetyModule = _modules.safetyModule;
        _modules.safetyModule = newSafetyModule;
        emit SafetyModuleUpdated(oldSafetyModule, newSafetyModule);
    }

    /// @inheritdoc IOllaVault
    function reconcileBufferedAssets() external override onlyOwner whenNotPaused returns (uint256 delta) {
        delta = _reconcileBufferedAssets(address(this));
        return delta;
    }

    /// @inheritdoc IOllaVault
    function recoverStAztec(address recipient, uint256 amount) external override onlyOwner whenNotPaused {
        if (amount == 0) revert OllaVault__InvalidAmount();
        address resolvedRecipient = recipient == address(0) ? _treasury() : recipient;
        IERC20(address(_modules.stAztec)).safeTransfer(resolvedRecipient, amount);
        emit StAztecRecovered(amount, resolvedRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-4626/7575 VIEW SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the share token address (ERC-7575).
    function share() external view override returns (address) {
        return address(_modules.stAztec);
    }

    /// @notice Returns max depositable assets (ERC-4626).
    function maxDeposit(address) external view override returns (uint256) {
        if (paused()) return 0;
        ISafetyModule sm = ISafetyModule(_modules.safetyModule);
        if (sm.isPaused()) return 0;
        uint256 cap = sm.depositCap();
        uint256 current = totalAssets();
        if (current >= cap) return 0;
        return cap - current;
    }

    /// @notice Returns max mintable shares (ERC-4626).
    function maxMint(address) external view override returns (uint256) {
        if (paused()) return 0;
        ISafetyModule sm = ISafetyModule(_modules.safetyModule);
        if (sm.isPaused()) return 0;
        uint256 cap = sm.depositCap();
        uint256 current = totalAssets();
        if (current >= cap) return 0;
        uint256 maxAssets = cap - current;
        return IOllaCore(_modules.core).convertToShares(maxAssets);
    }

    /// @notice Returns total claimable shares for controller (ERC-4626).
    function maxRedeem(address controller) external view override returns (uint256 maxShares) {
        uint256[] storage requestIds = _ownerRequestIds[controller];
        uint256 len = requestIds.length;
        IWithdrawalQueue queue = _modules.withdrawalQueue;
        // slither-disable-start calls-loop
        // Bounded by controller's own request count; users should prefer claimRequestById() for O(1) claims.
        for (uint256 i = 0; i < len; ++i) {
            IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(requestIds[i]);
            if (req.finalized && !req.claimed) {
                maxShares += req.shares;
            }
        }
        // slither-disable-end calls-loop
        return maxShares;
    }

    /// @notice Returns shares previewed for a deposit (ERC-4626).
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return IOllaCore(_modules.core).convertToShares(assets);
    }

    /// @notice Returns assets needed to mint exact shares (ERC-4626).
    function previewMint(uint256 shares) external view override returns (uint256) {
        return IOllaCore(_modules.core).convertToAssetsCeil(shares);
    }

    /// @notice Returns whether an operator is approved for a controller (ERC-7540).
    function isOperator(address controller, address operator) external view override returns (bool) {
        return _operators[controller][operator];
    }

    /// @notice Returns pending (unfinalized) shares for a request (ERC-7540).
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        override
        returns (uint256 pendingShares)
    {
        if (_requestOwners[requestId] != controller) return 0;
        IWithdrawalQueue.WithdrawalRequest memory request = _modules.withdrawalQueue.getRequest(requestId);
        if (!request.finalized && !request.claimed) return request.shares;
        return 0;
    }

    /// @notice Returns claimable (finalized, unclaimed) shares for a request (ERC-7540).
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        override
        returns (uint256 claimableShares)
    {
        if (_requestOwners[requestId] != controller) return 0;
        IWithdrawalQueue.WithdrawalRequest memory request = _modules.withdrawalQueue.getRequest(requestId);
        if (request.finalized && !request.claimed) return request.shares;
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the underlying asset address.
    function asset() external view override returns (address) {
        return address(_modules.asset);
    }

    /// @notice Returns the OllaCore address.
    function core() external view override returns (address) {
        return _modules.core;
    }

    /// @notice Returns the withdrawal queue module address.
    function withdrawalQueue() external view override returns (address) {
        return address(_modules.withdrawalQueue);
    }

    /// @notice Returns the safety module address.
    function safetyModule() external view override returns (address) {
        return _modules.safetyModule;
    }

    /// @notice Returns the recorded owner for a withdrawal request id.
    function requestOwner(uint256 requestId) external view override returns (address owner) {
        return _requestOwners[requestId];
    }

    /// @notice Returns the active withdrawal request ids for an owner.
    function activeRequestIds(address owner) external view override returns (uint256[] memory requestIds) {
        return _ownerRequestIds[owner];
    }

    /// @notice Returns current buffered (liquid) assets held by the Vault.
    function bufferedAssets() external view override returns (uint256) {
        return _bufferedAssets;
    }

    /// @notice Returns current pending withdrawal assets.
    function pendingWithdrawalAssets() external view override returns (uint256) {
        return _modules.withdrawalQueue.totalPendingAssets();
    }

    /// @notice Converts assets to shares (delegates to Core).
    function convertToShares(uint256 assets) external view override returns (uint256) {
        return IOllaCore(_modules.core).convertToShares(assets);
    }

    /// @notice Converts shares to assets (delegates to Core).
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return IOllaCore(_modules.core).convertToAssets(shares);
    }

    /// @notice Returns the net assets previewed for an instant redemption.
    function previewInstantRedeem(uint256 shares) external view override returns (uint256 assetsAfterFee) {
        uint256 grossAssets = IOllaCore(_modules.core).convertToAssets(shares);
        uint256 fee = grossAssets * instantRedemptionFeeBP / BP_DIVISOR;
        assetsAfterFee = grossAssets - fee;
        return assetsAfterFee;
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw is not supported for async vaults (ERC-7540).
    function withdraw(uint256, address, address) external pure override returns (uint256) {
        revert OllaVault__NotSupported();
    }

    /// @notice Returns 0 — withdraw is async (ERC-7540).
    function maxWithdraw(address) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Preview withdraw is not supported for async vaults (ERC-7540).
    function previewWithdraw(uint256) external pure override returns (uint256) {
        revert OllaVault__NotSupported();
    }

    /// @notice Preview redeem is not supported for async vaults (ERC-7540).
    function previewRedeem(uint256) external pure override returns (uint256) {
        revert OllaVault__NotSupported();
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-165 interface detection, extended for ERC-7540/ERC-7575.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == type(IERC7575).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Returns the total assets attributable to shareholders (ERC-4626).
    /// @dev Proxies to Core.totalAssets() — Core owns the pricing computation.
    function totalAssets() public view override returns (uint256) {
        return IOllaCore(_modules.core).totalAssets();
    }

    /// @notice Returns the maximum assets currently available for instant redemptions.
    function availableForInstantRedemption() public view override returns (uint256) {
        return _bufferedAssets;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address caller, uint256 assets, address recipient) internal returns (uint256 shares) {
        if (recipient == address(0)) revert OllaVault__ZeroAddress("recipient");
        if (assets == 0) revert OllaVault__InvalidAmount();

        VaultModules memory modules = _modules;
        ISafetyModule sm = ISafetyModule(modules.safetyModule);

        if (sm.isPaused()) revert OllaVault__SafetyModulePaused();

        _syncBufferedWithBalance();

        IOllaCore coreRef = IOllaCore(modules.core);
        uint256 currentTotalAssets = coreRef.totalAssets();
        if (!sm.checkDepositAllowed(assets, currentTotalAssets)) {
            revert OllaVault__DepositCapExceeded(assets, currentTotalAssets);
        }

        shares = coreRef.convertToShares(assets);
        modules.asset.safeTransferFrom(caller, address(this), assets);
        _bufferedAssets += assets;
        _syncBufferedWithBalance();
        cumulativeDeposits += assets;

        modules.stAztec.mint(recipient, shares);
        emit Deposit(caller, recipient, assets, shares);
        return shares;
    }

    /// @dev Shared logic for all async redemption paths.
    /// @param shareOwner  Address whose stAztec shares are burned.
    /// @param controller  Address that owns the withdrawal request (bookkeeping).
    /// @param recipient   Address passed to the WithdrawalQueue as the payout destination.
    function _executeRedeemRequest(address shareOwner, address controller, address recipient, uint256 shares)
        private
        returns (uint256 requestId)
    {
        if (shares == 0) revert OllaVault__InvalidAmount();

        VaultModules memory modules = _modules;
        IOllaCore coreRef = IOllaCore(modules.core);

        uint256 rate = coreRef.exchangeRate();
        uint256 assetsExpected = coreRef.convertToAssets(shares);
        ISafetyModule(modules.safetyModule).checkWithdrawalMinimum(shares);
        uint256 expectedRequestId = modules.withdrawalQueue.nextRequestId();

        _requestOwners[expectedRequestId] = controller;
        _ownerRequestIndex[expectedRequestId] = _ownerRequestIds[controller].length + 1;
        _ownerRequestIds[controller].push(expectedRequestId);
        cumulativeWithdrawals += assetsExpected;

        modules.stAztec.burn(shareOwner, shares);

        requestId = modules.withdrawalQueue.requestWithdrawal(recipient, shares, assetsExpected, rate);
        // slither-disable-next-line timestamp
        if (requestId != expectedRequestId) {
            revert OllaVault__UnexpectedRequestId(expectedRequestId, requestId);
        }

        emit WithdrawalRequested(requestId, shareOwner, recipient, shares, assetsExpected, rate);
        return requestId;
    }

    function _redeem(address owner, uint256 shares, address recipient) internal returns (uint256 netAssets) {
        if (recipient == address(0)) revert OllaVault__ZeroAddress("recipient");
        if (shares == 0) revert OllaVault__InvalidAmount();

        VaultModules memory modules = _modules;

        if (ISafetyModule(modules.safetyModule).isPaused()) revert OllaVault__SafetyModulePaused();

        _syncBufferedWithBalance();

        ISafetyModule(modules.safetyModule).checkWithdrawalMinimum(shares);

        IOllaCore coreRef = IOllaCore(modules.core);
        uint256 rate = coreRef.exchangeRate();
        uint256 grossAssets = coreRef.convertToAssets(shares);
        uint256 fee = grossAssets * instantRedemptionFeeBP / BP_DIVISOR;
        netAssets = grossAssets - fee;

        uint256 available = availableForInstantRedemption();
        // slither-disable-next-line timestamp
        if (grossAssets > available) revert OllaVault__InsufficientLiquidity(grossAssets, available);

        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
        modules.stAztec.burn(owner, shares);

        _bufferedAssets -= grossAssets;

        modules.asset.safeTransfer(recipient, netAssets);

        // slither-disable-next-line incorrect-equality
        if (fee != 0) {
            address treasuryAddr = _treasury();
            modules.asset.safeTransfer(treasuryAddr, fee);
        }

        cumulativeWithdrawals += grossAssets;

        emit InstantRedemption(owner, recipient, shares, grossAssets, fee, netAssets, rate);
        return netAssets;
    }

    /// @dev Claims a withdrawal request. If receiverOverride is address(0), uses the request's recipient.
    // slither-disable-next-line reentrancy-benign
    function _claimWithdrawal(uint256 requestId, address receiverOverride) internal returns (uint256 assets) {
        IWithdrawalQueue queue = _modules.withdrawalQueue;
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        if (!request.finalized) revert OllaVault__NotFinalized(requestId);
        address receiver = receiverOverride == address(0) ? request.recipient : receiverOverride;
        assets = request.assetsExpected;
        address requestOwnerAddr = _requestOwners[requestId];

        _removeOwnerRequest(requestOwnerAddr, requestId);
        delete _requestOwners[requestId];

        uint256 assetsClaimed = queue.claimWithdrawal(requestId);
        if (assetsClaimed != assets) revert OllaVault__ClaimAssetsMismatch(requestId, assets, assetsClaimed);

        _finalizedUnclaimedAssets -= assets;
        _modules.asset.safeTransfer(receiver, assets);
        emit WithdrawalClaimed(requestId, receiver, assets);
        return assets;
    }

    function _removeOwnerRequest(address requestOwnerAddr, uint256 requestId) internal {
        uint256 index = _ownerRequestIndex[requestId];
        if (index == 0) revert OllaVault__RequestNotFound(requestId);

        uint256[] storage requestIds = _ownerRequestIds[requestOwnerAddr];
        uint256 lastIndex = requestIds.length;
        uint256 removeIndex = index - 1;

        if (removeIndex != lastIndex - 1) {
            uint256 lastRequestId = requestIds[lastIndex - 1];
            requestIds[removeIndex] = lastRequestId;
            _ownerRequestIndex[lastRequestId] = index;
        }

        requestIds.pop();
        delete _ownerRequestIndex[requestId];
    }

    function _reconcileBufferedAssets(address recipient) internal returns (uint256 delta) {
        uint256 buffered = _bufferedAssets;
        uint256 actual = _modules.asset.balanceOf(address(this));
        if (actual < _finalizedUnclaimedAssets) {
            revert OllaVault__BufferedBalanceMismatch(buffered, actual);
        }
        uint256 available = actual - _finalizedUnclaimedAssets;
        // slither-disable-next-line timestamp
        if (available < buffered) {
            revert OllaVault__BufferedBalanceMismatch(buffered, available);
        }
        delta = available - buffered;
        if (delta != 0) {
            _bufferedAssets = available;
            emit BufferedAssetsReconciled(delta, available, recipient);
        }
        return delta;
    }

    function _syncBufferedWithBalance() internal {
        _reconcileBufferedAssets(address(this));
    }

    function _checkControllerOrOperator(address controller) internal view {
        if (msg.sender != controller && !_operators[controller][msg.sender]) {
            revert OllaVault__Unauthorized();
        }
    }

    /// @dev Linear scan for ERC-7540 redeem() compatibility. Prefer claimRequestById() for O(1) claims.
    function _findClaimableRequest(address controller, uint256 shares) internal view returns (uint256 requestId) {
        uint256[] storage requestIds = _ownerRequestIds[controller];
        uint256 len = requestIds.length;
        IWithdrawalQueue queue = _modules.withdrawalQueue;
        // slither-disable-start calls-loop
        // Bounded by controller's own request count; ERC-7540 compat only.
        for (uint256 i = 0; i < len; ++i) {
            uint256 id = requestIds[i];
            IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(id);
            if (req.finalized && !req.claimed && req.shares == shares) {
                return id;
            }
        }
        // slither-disable-end calls-loop
        revert OllaVault__RequestNotFound(0);
    }

    function _treasury() internal view returns (address) {
        return IOllaGovernance(owner()).treasury();
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert OllaVault__ZeroAddress("newImplementation");
    }
}
