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
import { ReentrancyGuardTransient } from "@oz/utils/ReentrancyGuardTransient.sol";
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
    ReentrancyGuardTransient,
    IOllaVault
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for guardian pause/unpause actions.
    bytes32 public constant GUARDIAN_ROLE = RolesLib.GUARDIAN_ROLE;

    /// @notice Role that only OllaCore holds -- for rebalance instructions.
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    /// @notice Basis points divisor.
    uint256 public constant BP_DIVISOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract related interfaces and addresses.
    VaultModules private _modules;

    /// @notice Buffer tracking -- liquid assets held by the vault.
    uint256 private _bufferedAssets;

    /// @notice Assets that have been finalized but not yet claimed.
    uint256 private _finalizedUnclaimedAssets;

    /// @notice Withdrawal request tracking.
    mapping(uint256 requestId => address owner) private _requestOwners;
    mapping(address owner => uint256[] requestIds) private _ownerRequestIds;
    mapping(uint256 requestId => uint256 index) private _ownerRequestIndex;

    /// @notice ERC-7540 operator approvals: controller -> operator -> approved.
    mapping(address controller => mapping(address operator => bool approved)) private _operators;

    /// @notice Cumulative deposits tracked for Core accounting.
    uint256 public cumulativeDeposits;

    /// @notice Cumulative withdrawals tracked for Core accounting.
    uint256 public cumulativeWithdrawals;

    /// @notice Cumulative slashing adjustments tracked for Core accounting.
    uint256 public cumulativeSlashingAdjustments;

    /// @notice Cached claimable shares per controller for O(1) maxRedeem.
    mapping(address controller => uint256 shares) private _claimableShares;

    /// @notice Storage gap for future upgrades.
    /// @dev When adding new state variables, append them above this gap and reduce its length
    ///      by the number of slots consumed. Target: 50 gap slots across all upgradeable contracts.
    // slither-disable-next-line unused-state
    uint256[50] private __gap;

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
        address core_,
        address governanceContract_
    ) external override initializer {
        if (address(asset_) == address(0)) revert OllaVault__ZeroAddress("asset_");
        if (address(stAztec_) == address(0)) revert OllaVault__ZeroAddress("stAztec_");
        if (withdrawalQueue_ == address(0)) revert OllaVault__ZeroAddress("withdrawalQueue_");
        if (core_ == address(0)) revert OllaVault__ZeroAddress("core_");
        if (governanceContract_ == address(0)) revert OllaVault__ZeroAddress("governanceContract_");

        __Ownable_init(governanceContract_);
        __AccessControl_init();
        __Pausable_init();
        _pause();

        _modules = VaultModules({
            asset: asset_, stAztec: stAztec_, withdrawalQueue: IWithdrawalQueue(withdrawalQueue_), core: core_
        });

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
        // Slippage bound check; not a timestamp concern.
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
        // ERC-20 permit call on trusted asset token; sets allowance only.
        // Wrapped in try/catch for frontrun protection: if an attacker consumes the
        // permit signature first, the allowance is already set and the deposit can
        // proceed. Only reverts when the permit fails AND no sufficient allowance exists.
        // slither-disable-next-line reentrancy-benign
        try IERC20Permit(address(_modules.asset)).permit(msg.sender, address(this), assets, deadline, v, r, s) { }
        catch (bytes memory reason) {
            if (_modules.asset.allowance(msg.sender, address(this)) < assets) {
                revert OllaVault__PermitFailed(reason);
            }
        }
        shares = _deposit(msg.sender, assets, recipient);
        // Slippage bound check; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (shares < minSharesOut) revert OllaVault__SlippageExceeded(shares, minSharesOut);
        return shares;
    }

    /// @inheritdoc IOllaVault
    function requestRedeemWithPermit(
        uint256 shares,
        address controller,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant whenNotPaused returns (uint256 requestId) {
        if (controller == address(0)) revert OllaVault__ZeroAddress("controller");
        IStAztec stAztecRef = _modules.stAztec;
        // ERC-20 permit call on trusted stAztec token; sets allowance only.
        // Wrapped in try/catch for frontrun protection: if an attacker consumes the
        // permit signature first, the allowance is already set and the redeem request
        // can proceed. Only reverts when the permit fails AND no sufficient allowance exists.
        // slither-disable-next-line reentrancy-benign
        try stAztecRef.permit(msg.sender, address(this), shares, deadline, v, r, s) { }
        catch (bytes memory reason) {
            if (stAztecRef.allowance(msg.sender, address(this)) < shares) {
                revert OllaVault__PermitFailed(reason);
            }
        }
        // Pull shares to vault via transferFrom, consuming the permit-set allowance.
        // slither-disable-next-line reentrancy-benign
        IERC20(address(stAztecRef)).safeTransferFrom(msg.sender, address(this), shares);
        uint256 assets;
        (requestId, assets) = _executeRedeemRequest(msg.sender, controller, controller, shares, true);

        emit RedeemRequest(controller, msg.sender, requestId, msg.sender, assets);
        return requestId;
    }

    /// @inheritdoc IOllaVault
    function claimRequestById(uint256 requestId) external override nonReentrant whenNotPaused returns (uint256 assets) {
        if (_ownerRequestIndex[requestId] == 0) revert OllaVault__RequestNotFound(requestId);
        _checkControllerOrOperator(_requestOwners[requestId]);
        assets = _claimWithdrawal(requestId, address(0));
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-4626/7575 SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits assets and mints shares to receiver (ERC-4626).
    /// @dev This standard overload has NO slippage protection. Prefer the 3-arg
    ///      `deposit(assets, receiver, minSharesOut)` variant for front-run safety.
    /// @param assets The amount of underlying assets to deposit.
    /// @param receiver The address that will receive the minted shares.
    /// @return shares The amount of shares minted.
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
    /// @param shares The exact amount of shares to mint.
    /// @param receiver The address that will receive the minted shares.
    /// @return assets The amount of underlying assets deposited.
    function mint(uint256 shares, address receiver)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert OllaVault__ZeroAddress("receiver");
        if (shares == 0) revert OllaVault__InvalidAmount();

        ISafetyModule sm = ISafetyModule(_safetyModule());
        if (sm.isPaused()) revert OllaVault__SafetyModulePaused();
        _syncBufferedWithBalance();

        IOllaCore coreRef = IOllaCore(_modules.core);
        assets = coreRef.convertToAssetsCeil(shares);

        uint256 currentTotalAssets = coreRef.totalAssets();
        if (!sm.checkDepositAllowed(assets, currentTotalAssets)) {
            revert OllaVault__DepositCapExceeded(assets, currentTotalAssets);
        }

        _processDeposit(msg.sender, assets, shares, receiver);
        return assets;
    }

    /// @notice Claims a finalized async redeem request (ERC-4626/ERC-7540).
    /// @param shares The amount of shares to redeem.
    /// @param receiver The address that will receive the redeemed assets.
    /// @param controller The controller whose request is being claimed.
    /// @return assets The amount of underlying assets returned.
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
    /// @param operator The address to set as operator.
    /// @param approved Whether the operator is approved.
    /// @return Whether the call succeeded.
    function setOperator(address operator, bool approved) external override returns (bool) {
        if (operator == msg.sender) revert OllaVault__InvalidParameter();
        if (approved && paused()) revert PausableUpgradeable.EnforcedPause();
        _operators[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @notice Requests an async redemption (ERC-7540).
    /// @param shares The amount of shares to redeem.
    /// @param controller The controller address for the request.
    /// @param owner The owner of the shares being redeemed.
    /// @return requestId The id of the created withdrawal request.
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

        uint256 assets;
        (requestId, assets) = _executeRedeemRequest(owner, controller, controller, shares, false);

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
        uint256 newBuffered = _bufferedAssets + amount;
        _bufferedAssets = newBuffered;

        // Defense-in-depth: verify the real balance backs the updated accounting.
        uint256 actual = _modules.asset.balanceOf(address(this));
        uint256 required = _finalizedUnclaimedAssets + newBuffered;
        if (actual < required) {
            revert OllaVault__BufferedBalanceMismatch(newBuffered, actual - _finalizedUnclaimedAssets);
        }

        emit UnstakedAssetsReceived(amount);
    }

    // solhint-disable function-max-lines
    /// @inheritdoc IOllaVault
    function finalizeWithdrawals(uint256 availableAssets, uint256 currentRate)
        external
        override
        onlyRole(CORE_ROLE)
        returns (uint256 finalizedAmount, uint256 finalizedCount)
    {
        // slither-disable-start reentrancy-events,reentrancy-no-eth,reentrancy-benign
        // CORE_ROLE only; all external calls target trusted WithdrawalQueue.
        // Zero-amount short circuit; not a timestamp concern.
        // slither-disable-next-line timestamp,incorrect-equality
        if (availableAssets == 0) return (0, 0);

        IWithdrawalQueue queue = _modules.withdrawalQueue;
        uint256 queued = queue.totalPendingAssets();
        // No pending requests; not a timestamp concern.
        // slither-disable-next-line timestamp,incorrect-equality
        if (queued == 0) return (0, 0);

        uint256 prevPending = queue.nextUnfinalized();
        uint256 totalAdjusted;
        (finalizedAmount, finalizedCount, totalAdjusted) = queue.finalizeWithdrawals(availableAssets, currentRate);

        uint256 queuedAfter = queue.totalPendingAssets();
        if (queued - queuedAfter != finalizedAmount + totalAdjusted) {
            revert OllaVault__FinalizeAmountMismatch(queued - queuedAfter, finalizedAmount + totalAdjusted);
        }

        uint256 buffered = _bufferedAssets;
        if (finalizedAmount > buffered) {
            revert OllaVault__InsufficientBufferedAssets(finalizedAmount, buffered);
        }

        // Consistency invariant: both must be zero or both non-zero.
        // slither-disable-next-line incorrect-equality
        if ((finalizedAmount == 0) != (finalizedCount == 0)) {
            revert OllaVault__FinalizeInconsistent(finalizedAmount, finalizedCount);
        }

        // Nothing finalized; short circuit.
        // slither-disable-next-line incorrect-equality
        if (finalizedAmount == 0 && totalAdjusted == 0) return (0, 0);

        if (finalizedAmount > 0) {
            _bufferedAssets = buffered - finalizedAmount;
            _finalizedUnclaimedAssets += finalizedAmount;
        }

        // Track slashing adjustments separately to preserve cumulativeWithdrawals monotonicity.
        if (totalAdjusted > 0) {
            cumulativeSlashingAdjustments += totalAdjusted;
        }

        // Update per-controller claimable shares for O(1) maxRedeem.
        // slither-disable-start calls-loop
        // Bounded by finalizedCount; same requests the queue already processed.
        uint256 newPending = queue.nextUnfinalized();
        for (uint256 id = prevPending; id < newPending; ++id) {
            IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(id);
            if (req.finalized) {
                _claimableShares[_requestOwners[id]] += req.shares;
            }
        }
        // slither-disable-end calls-loop

        // CORE_ROLE only; external call to trusted WithdrawalQueue.
        emit WithdrawalFinalized(availableAssets, finalizedAmount);
        return (finalizedAmount, finalizedCount);
        // slither-disable-end reentrancy-events,reentrancy-no-eth,reentrancy-benign
    }

    // solhint-enable function-max-lines

    /// @inheritdoc IOllaVault
    function mintFees(address treasury, uint256 treasuryShares, address provider, uint256 providerShares)
        external
        override
        onlyRole(CORE_ROLE)
    {
        // slither-disable-start reentrancy-events
        // CORE_ROLE only; stAztec.mint() is a trusted internal token.
        IStAztec stAztecRef = _modules.stAztec;
        if (treasuryShares > 0) stAztecRef.mint(treasury, treasuryShares);
        if (providerShares > 0) stAztecRef.mint(provider, providerShares);
        emit FeesMinted(treasuryShares, providerShares);
        // slither-disable-end reentrancy-events
    }

    /*//////////////////////////////////////////////////////////////
                      PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaVault
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @inheritdoc IOllaVault
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaVault
    function reconcileBufferedAssets() external override onlyOwner whenNotPaused returns (uint256 delta) {
        delta = _reconcileBufferedAssets(address(this));
        return delta;
    }

    /// @inheritdoc IOllaVault
    /// @notice Updates the gas threshold used by the withdrawal queue's finalization loop.
    /// @dev Only callable by governance (owner). The gas threshold controls how many withdrawal
    ///      requests can be processed per `finalizeWithdrawals()` call before the loop exits.
    function setQueueGasThreshold(uint256 threshold) external override onlyOwner {
        uint256 oldThreshold = _modules.withdrawalQueue.gasThreshold();
        emit QueueGasThresholdUpdated(oldThreshold, threshold);
        _modules.withdrawalQueue.setGasThreshold(threshold);
    }

    /// @inheritdoc IOllaVault
    function recoverStAztec(address recipient, uint256 amount) external override onlyOwner {
        if (amount == 0) revert OllaVault__InvalidAmount();
        address resolvedRecipient = recipient == address(0) ? _treasury() : recipient;
        IERC20(address(_modules.stAztec)).safeTransfer(resolvedRecipient, amount);
        emit StAztecRecovered(amount, resolvedRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-4626/7575 VIEW SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the share token address (ERC-7575).
    /// @return The share token address.
    function share() external view override returns (address) {
        return address(_modules.stAztec);
    }

    /// @notice Returns max depositable assets (ERC-4626).
    /// @return The max depositable assets.
    // solhint-disable-next-line use-natspec
    function maxDeposit(address) external view override returns (uint256) {
        if (paused()) return 0;
        ISafetyModule sm = ISafetyModule(_safetyModule());
        if (sm.isPaused()) return 0;
        uint256 cap = sm.depositCap();
        uint256 current = totalAssets();
        if (current >= cap) return 0;
        return cap - current;
    }

    /// @notice Returns max mintable shares (ERC-4626).
    /// @return The max mintable shares.
    // solhint-disable-next-line use-natspec
    function maxMint(address) external view override returns (uint256) {
        if (paused()) return 0;
        ISafetyModule sm = ISafetyModule(_safetyModule());
        if (sm.isPaused()) return 0;
        uint256 cap = sm.depositCap();
        uint256 current = totalAssets();
        if (current >= cap) return 0;
        uint256 maxAssets = cap - current;
        return IOllaCore(_modules.core).convertToShares(maxAssets);
    }

    /// @notice Returns total claimable shares for controller (ERC-4626).
    /// @param controller The controller address.
    /// @return maxShares The total claimable shares.
    /// @dev Returns 0 when the vault is paused, per ERC-7540 requirement that maxRedeem
    ///      reflects the maximum currently redeemable amount. When paused, redeem() reverts,
    ///      so maxRedeem must return 0 to signal non-availability to integrators.
    function maxRedeem(address controller) external view override returns (uint256 maxShares) {
        if (paused()) return 0;
        return _claimableShares[controller];
    }

    /// @notice Returns shares previewed for a deposit (ERC-4626).
    /// @param assets The deposit amount.
    /// @return The shares previewed.
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return IOllaCore(_modules.core).convertToShares(assets);
    }

    /// @notice Returns assets needed to mint exact shares (ERC-4626).
    /// @param shares The share amount.
    /// @return The assets needed.
    function previewMint(uint256 shares) external view override returns (uint256) {
        return IOllaCore(_modules.core).convertToAssetsCeil(shares);
    }

    /// @notice Returns whether an operator is approved for a controller (ERC-7540).
    /// @param controller The controller address.
    /// @param operator The operator address.
    /// @return Whether the operator is approved.
    function isOperator(address controller, address operator) external view override returns (bool) {
        return _operators[controller][operator];
    }

    /// @notice Returns pending (unfinalized) shares for a request (ERC-7540).
    /// @param requestId The withdrawal request id.
    /// @param controller The controller address.
    /// @return pendingShares The pending (unfinalized) shares.
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
    /// @param requestId The withdrawal request id.
    /// @param controller The controller address.
    /// @return claimableShares The claimable (finalized, unclaimed) shares.
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
    /// @return The underlying asset address.
    function asset() external view override returns (address) {
        return address(_modules.asset);
    }

    /// @notice Returns the OllaCore address.
    /// @return The OllaCore address.
    function core() external view override returns (address) {
        return _modules.core;
    }

    /// @notice Returns the withdrawal queue module address.
    /// @return The withdrawal queue address.
    function withdrawalQueue() external view override returns (address) {
        return address(_modules.withdrawalQueue);
    }

    /// @notice Returns the safety module address (reads canonical reference from Core).
    /// @return The safety module address.
    function safetyModule() external view override returns (address) {
        return _safetyModule();
    }

    /// @notice Returns the recorded owner for a withdrawal request id.
    /// @param requestId The withdrawal request id.
    /// @return owner The recorded owner address.
    function requestOwner(uint256 requestId) external view override returns (address owner) {
        return _requestOwners[requestId];
    }

    /// @notice Returns the active withdrawal request ids for an owner.
    /// @param owner The owner address.
    /// @return requestIds The active withdrawal request ids.
    function activeRequestIds(address owner) external view override returns (uint256[] memory requestIds) {
        return _ownerRequestIds[owner];
    }

    /// @notice Returns current buffered (liquid) assets held by the Vault.
    /// @return The current buffered assets.
    function bufferedAssets() external view override returns (uint256) {
        return _bufferedAssets;
    }

    /// @notice Returns current pending withdrawal assets.
    /// @return The current pending withdrawal assets.
    function pendingWithdrawalAssets() external view override returns (uint256) {
        return _modules.withdrawalQueue.totalPendingAssets();
    }

    /// @inheritdoc IOllaVault
    function pendingWithdrawalShares() external view override returns (uint256) {
        return _modules.withdrawalQueue.totalPendingShares();
    }

    /// @notice Converts assets to shares (delegates to Core).
    /// @param assets The amount of assets to convert.
    /// @return The computed share amount.
    function convertToShares(uint256 assets) external view override returns (uint256) {
        return IOllaCore(_modules.core).convertToShares(assets);
    }

    /// @notice Converts shares to assets (delegates to Core).
    /// @param shares The amount of shares to convert.
    /// @return The computed asset amount.
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return IOllaCore(_modules.core).convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw is not supported for async vaults (ERC-7540).
    /// @return Always reverts.
    // solhint-disable-next-line use-natspec
    function withdraw(uint256, address, address) external pure override returns (uint256) {
        revert OllaVault__NotSupported();
    }

    /// @notice Returns 0 -- withdraw is async (ERC-7540).
    /// @return Always 0.
    // solhint-disable-next-line use-natspec
    function maxWithdraw(address) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Preview withdraw is not supported for async vaults (ERC-7540).
    /// @return Always reverts.
    // solhint-disable-next-line use-natspec
    function previewWithdraw(uint256) external pure override returns (uint256) {
        revert OllaVault__NotSupported();
    }

    /// @notice Preview redeem is not supported for async vaults (ERC-7540).
    /// @return Always reverts.
    // solhint-disable-next-line use-natspec
    function previewRedeem(uint256) external pure override returns (uint256) {
        revert OllaVault__NotSupported();
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function renounceOwnership() public view override onlyOwner {
        revert("renouncing ownership not allowed");
    }

    /// @notice ERC-165 interface detection, extended for ERC-7540/ERC-7575.
    /// @param interfaceId The interface identifier to check.
    /// @return Whether the interface is supported.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == type(IERC7575).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Returns the total assets attributable to shareholders (ERC-4626).
    /// @dev Proxies to Core.totalAssets() -- Core owns the pricing computation.
    /// @return The total assets.
    function totalAssets() public view override returns (uint256) {
        return IOllaCore(_modules.core).totalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates deposit preconditions (safety module, cap) and computes shares.
    /// @param caller The depositor address.
    /// @param assets The amount of assets to deposit.
    /// @param recipient The receiver of the minted shares.
    /// @return shares The amount of shares minted.
    function _deposit(address caller, uint256 assets, address recipient) internal returns (uint256 shares) {
        if (recipient == address(0)) revert OllaVault__ZeroAddress("recipient");
        if (assets == 0) revert OllaVault__InvalidAmount();

        ISafetyModule sm = ISafetyModule(_safetyModule());
        if (sm.isPaused()) revert OllaVault__SafetyModulePaused();
        _syncBufferedWithBalance();

        IOllaCore coreRef = IOllaCore(_modules.core);
        uint256 currentTotalAssets = coreRef.totalAssets();
        if (!sm.checkDepositAllowed(assets, currentTotalAssets)) {
            revert OllaVault__DepositCapExceeded(assets, currentTotalAssets);
        }

        shares = coreRef.convertToShares(assets);
        _processDeposit(caller, assets, shares, recipient);
        return shares;
    }

    /// @notice Transfers assets from caller, updates buffered accounting, mints shares, and emits Deposit.
    /// @dev Credits the nominal transfer amount directly. This assumes the AZTEC token has no
    ///      fee-on-transfer or rebasing behavior. Verified: AZTEC token is a non-upgradeable
    ///      OpenZeppelin ERC-20 with no transfer hooks. This assumption is immutable - the token
    ///      contract has no proxy and cannot be upgraded.
    /// @param caller The address providing the assets.
    /// @param assets The amount of assets transferred in.
    /// @param shares The amount of shares to mint.
    /// @param recipient The receiver of the minted shares.
    function _processDeposit(address caller, uint256 assets, uint256 shares, address recipient) internal {
        if (shares == 0) revert OllaVault__InvalidAmount();

        VaultModules memory modules = _modules;
        modules.asset.safeTransferFrom(caller, address(this), assets);
        _bufferedAssets += assets;
        _syncBufferedWithBalance();
        cumulativeDeposits += assets;

        modules.stAztec.mint(recipient, shares);
        emit Deposit(caller, recipient, assets, shares);
    }

    /// @notice Executes the shared logic for all async redemption paths.
    /// @param shareOwner  Address whose stAztec shares are burned.
    /// @param controller  Address that owns the withdrawal request (bookkeeping).
    /// @param recipient   Address passed to the WithdrawalQueue as the payout destination.
    /// @param shares      The amount of shares to redeem.
    /// @param sharesPulledToVault True when shares were already transferred to the vault
    ///        (permit paths use safeTransferFrom to consume the allowance).
    /// @return requestId  The withdrawal request id.
    /// @return assetsExpected The expected asset amount for the redeemed shares.
    function _executeRedeemRequest(
        address shareOwner,
        address controller,
        address recipient,
        uint256 shares,
        bool sharesPulledToVault
    ) internal returns (uint256 requestId, uint256 assetsExpected) {
        if (shares == 0) revert OllaVault__InvalidAmount();

        VaultModules memory modules = _modules;
        IOllaCore coreRef = IOllaCore(modules.core);

        // Settlement rate and assetsExpected are both computed in the gross per-share-backing
        // frame, so `request.rate` stored here matches `currentRate` at finalize -- the slashing-
        // adjustment gate compares like-for-like quantities and only fires on real slashing.
        uint256 rate = coreRef.withdrawalRate();
        assetsExpected = coreRef.convertToAssetsGross(shares);
        ISafetyModule(_safetyModule()).checkWithdrawalMinimum(shares);
        uint256 expectedRequestId = modules.withdrawalQueue.nextRequestId();

        _requestOwners[expectedRequestId] = controller;
        _ownerRequestIndex[expectedRequestId] = _ownerRequestIds[controller].length + 1;
        _ownerRequestIds[controller].push(expectedRequestId);
        cumulativeWithdrawals += assetsExpected;

        // Permit paths pull shares to vault via safeTransferFrom before calling this function,
        // so burn from vault's balance. Non-permit paths burn directly from the share owner.
        modules.stAztec.burn(sharesPulledToVault ? address(this) : shareOwner, shares);

        requestId = modules.withdrawalQueue.requestWithdrawal(recipient, shares, assetsExpected, rate);
        // Request ID consistency check; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (requestId != expectedRequestId) {
            revert OllaVault__UnexpectedRequestId(expectedRequestId, requestId);
        }

        return (requestId, assetsExpected);
    }

    /// @dev Claims a withdrawal request. If receiverOverride is address(0), uses the request's recipient.
    // Trusted WithdrawalQueue; marks request as claimed and returns asset amount.
    // slither-disable-next-line reentrancy-benign
    function _claimWithdrawal(uint256 requestId, address receiverOverride) internal returns (uint256 assets) {
        IWithdrawalQueue queue = _modules.withdrawalQueue;
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        if (!request.finalized) revert OllaVault__NotFinalized(requestId);
        address receiver = receiverOverride == address(0) ? request.recipient : receiverOverride;
        assets = request.assetsExpected;
        address requestOwnerAddr = _requestOwners[requestId];

        _claimableShares[requestOwnerAddr] -= request.shares;
        _removeOwnerRequest(requestOwnerAddr, requestId);
        delete _requestOwners[requestId];

        uint256 assetsClaimed = queue.claimWithdrawal(requestId);
        if (assetsClaimed != assets) revert OllaVault__ClaimAssetsMismatch(requestId, assets, assetsClaimed);

        _finalizedUnclaimedAssets -= assets;
        _modules.asset.safeTransfer(receiver, assets);
        emit WithdrawalClaimed(requestId, receiver, assets);
        return assets;
    }

    /// @notice Removes a request from the owner's tracked array using swap-and-pop.
    /// @param requestOwnerAddr The owner of the request.
    /// @param requestId The withdrawal request id to remove.
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

    /// @notice Reconciles internal buffered accounting with actual token balance, absorbing any positive delta.
    /// @param recipient The address associated with the reconciliation event.
    /// @return delta The positive difference absorbed into buffered assets.
    function _reconcileBufferedAssets(address recipient) internal returns (uint256 delta) {
        uint256 buffered = _bufferedAssets;
        uint256 actual = _modules.asset.balanceOf(address(this));
        if (actual < _finalizedUnclaimedAssets) {
            revert OllaVault__BufferedBalanceMismatch(buffered, actual);
        }
        uint256 available = actual - _finalizedUnclaimedAssets;
        // Balance integrity check; not a timestamp concern.
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

    /// @notice Convenience wrapper: reconciles buffered assets without emitting a recipient-specific event.
    function _syncBufferedWithBalance() internal {
        _reconcileBufferedAssets(address(this));
    }

    /// @notice Reverts unless msg.sender is the controller or an approved operator.
    /// @param controller The controller address to check against.
    function _checkControllerOrOperator(address controller) internal view {
        if (msg.sender != controller && !_operators[controller][msg.sender]) {
            revert OllaVault__Unauthorized();
        }
    }

    /// @dev Linear scan for ERC-7540 redeem() compatibility. Prefer claimRequestById() for O(1) claims.
    ///      Selection is non-deterministic for equal-sized requests because swap-and-pop on claim
    ///      changes array order. The user gets a valid finalized request regardless of which one is
    ///      selected. Integrators should use `claimRequestById()` when request identity matters.
    function _findClaimableRequest(address controller, uint256 shares) internal view returns (uint256 requestId) {
        uint256[] storage requestIds = _ownerRequestIds[controller];
        uint256 len = requestIds.length;
        IWithdrawalQueue queue = _modules.withdrawalQueue;
        // slither-disable-start calls-loop
        // Bounded by the controller's own request count; ERC-7540 redeem() compat path only.
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

    /// @notice Returns the canonical SafetyModule address from Core.
    /// @return The safety module address.
    function _safetyModule() internal view returns (address) {
        return IOllaCore(_modules.core).safetyModule();
    }

    /// @notice Returns the treasury address from the OllaGovernance owner.
    /// @return The treasury address.
    function _treasury() internal view returns (address) {
        return IOllaGovernance(owner()).treasury();
    }

    /// @notice Authorizes a UUPS upgrade; reverts if newImplementation is zero.
    /// @param newImplementation The address of the new implementation contract.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert OllaVault__ZeroAddress("newImplementation");
    }
}
