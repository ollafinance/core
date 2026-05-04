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
import { SafeCast } from "@oz/utils/math/SafeCast.sol";
import { ReentrancyGuardTransient } from "@oz/utils/ReentrancyGuardTransient.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { RolesLib } from "src/shared/RolesLib.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";

/// @title OllaVault
/// @notice User-facing ERC-7540/ERC-7575/ERC-4626 vault.
/// @dev Holds assets, mints/burns stAztec, and manages withdrawal requests in-place.
///      The withdrawal queue (formerly a separate proxy) is folded into this contract
///      so that finalize is a single self-contained loop. Pricing is delegated to OllaCore.
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

    /// @notice Tolerance for rate comparison in slashing adjustment (1 wei).
    /// @dev Accounts for floor-rounding differences between the gross rate
    ///      (computed on aggregate state) and per-request rates.
    uint256 private constant _SLASHING_RATE_TOLERANCE = 1;

    /// @notice Scale factor for exchange rate calculations.
    uint256 private constant _RATE_SCALE = 1e18;

    /// @notice Gas safety net for the finalization loop.
    /// @dev With the queue folded into the vault there is no longer a cross-contract loop sharing
    ///      a gas budget, so this threshold is purely a defensive cap on per-call work. Callers
    ///      should still bound their batch via `maxRequestId` for predictable rebalance pacing.
    uint256 private constant _FINALIZE_GAS_THRESHOLD = 150_000;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract related interfaces and addresses.
    VaultModules private _modules;

    /// @notice Buffer tracking -- liquid assets held by the vault.
    uint256 private _bufferedAssets;

    /// @notice Assets that have been finalized but not yet claimed.
    uint256 private _finalizedUnclaimedAssets;

    /// @notice Next request id to assign (starts at 1; id 0 is reserved as "none").
    uint64 private _nextRequestId;

    /// @notice Next request id to consider for finalization (the queue head).
    uint64 private _nextPendingId;

    /// @notice Stored withdrawal requests by id.
    mapping(uint256 requestId => WithdrawalRequest request) private _requests;

    /// @notice Total assets outstanding across unfinalized requests.
    uint256 public override pendingWithdrawalAssets;

    /// @notice Total shares outstanding across unfinalized requests (burned but not yet finalized).
    uint256 public override pendingWithdrawalShares;

    /// @notice Withdrawal request ownership tracking.
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
    uint256[44] private __gap;

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
    function initialize(IERC20 asset_, IStAztec stAztec_, address core_, address governanceContract_)
        external
        override
        initializer
    {
        if (address(asset_) == address(0)) revert OllaVault__ZeroAddress("asset_");
        if (address(stAztec_) == address(0)) revert OllaVault__ZeroAddress("stAztec_");
        if (core_ == address(0)) revert OllaVault__ZeroAddress("core_");
        if (governanceContract_ == address(0)) revert OllaVault__ZeroAddress("governanceContract_");

        __Ownable_init(governanceContract_);
        __AccessControl_init();
        __Pausable_init();
        _pause();

        _modules = VaultModules({ asset: asset_, stAztec: stAztec_, core: core_ });

        _nextRequestId = 1;
        _nextPendingId = 1;

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
    function mint(uint256 shares, address receiver, uint256 maxAssetsIn)
        external
        override(IOllaVault)
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        assets = _mintShares(msg.sender, shares, receiver);
        // Slippage bound check; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (assets > maxAssetsIn) revert OllaVault__SlippageExceeded(assets, maxAssetsIn);
        return assets;
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
        (requestId,) = _executeRedeemRequest(msg.sender, controller, shares, true);

        emit RedeemRequest(controller, msg.sender, requestId, msg.sender, shares);
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
    /// @dev This standard overload has NO slippage protection. Prefer the 3-arg
    ///      `mint(shares, receiver, maxAssetsIn)` variant for front-run safety.
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
        return _mintShares(msg.sender, shares, receiver);
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
        if (controller == address(0)) revert OllaVault__ZeroAddress("controller");

        if (msg.sender != owner && !_operators[owner][msg.sender]) {
            // ERC-7540 spec: ERC-20 share allowance is a valid authorization path.
            // safeTransferFrom reverts on insufficient allowance — the allowance check
            // IS the authorization, so the arbitrary `from` is intentional and bounded.
            // slither-disable-next-line arbitrary-send-erc20,pess-nft-approve-warning
            IERC20(address(_modules.stAztec)).safeTransferFrom(owner, address(this), shares);
            (requestId,) = _executeRedeemRequest(owner, controller, shares, true);
        } else {
            (requestId,) = _executeRedeemRequest(owner, controller, shares, false);
        }

        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
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
    function finalizeWithdrawals(uint256 availableAssets, uint256 currentRate, uint256 maxRequestId)
        external
        override
        onlyRole(CORE_ROLE)
        returns (uint256 finalizedAmount, uint256 finalizedCount)
    {
        return _finalizeWithdrawals(availableAssets, currentRate, maxRequestId);
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
        if (sm.isDepositPaused()) return 0;
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
        if (sm.isDepositPaused()) return 0;
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

    // slither-disable-start pess-multiple-storage-read
    // Reads a single request struct; multiple field accesses on the same _requests slot are required.
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
        WithdrawalRequest storage request = _requests[requestId];
        if (!request.finalized) return request.shares;
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
        WithdrawalRequest storage request = _requests[requestId];
        if (request.finalized) return request.shares;
        return 0;
    }

    // slither-disable-end pess-multiple-storage-read

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

    /// @inheritdoc IOllaVault
    function nextWithdrawalRequestId() external view override returns (uint256 requestId) {
        return _nextRequestId;
    }

    /// @inheritdoc IOllaVault
    function nextUnfinalizedWithdrawalRequestId() external view override returns (uint256 requestId) {
        return _nextPendingId;
    }

    /// @inheritdoc IOllaVault
    function getWithdrawalRequest(uint256 requestId) external view override returns (WithdrawalRequest memory request) {
        if (_requestOwners[requestId] == address(0)) revert OllaVault__RequestNotFound(requestId);
        return _requests[requestId];
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

    // solhint-disable function-max-lines
    // slither-disable-start cyclomatic-complexity,pess-multiple-storage-read
    // FIFO finalization intentionally reads sequential request storage entries; complexity reflects
    // the slashing-adjustment / liquidity / event-emit branches inherent to the loop body.
    /// @notice Finalizes pending withdrawal requests up to, but not including, `maxRequestId`.
    /// @dev Single self-contained loop. Per-controller `_claimableShares` is updated inline as
    ///      each request transitions to finalized, removing the previous outer loop in the vault
    ///      that shared a gas budget with a separate queue contract. The loop is bounded only
    ///      by `maxRequestId`; the prior `gasleft()` heuristic is no longer needed.
    /// @param availableAssets The asset budget available to satisfy pending requests this batch.
    /// @param currentRate The current shares-to-assets rate applied to finalized requests.
    /// @param maxRequestId Exclusive upper bound on request ids to consider for finalization.
    /// @return finalizedAmount The total assets allocated to requests finalized in this call.
    /// @return finalizedCount The number of requests transitioned to finalized in this call.
    function _finalizeWithdrawals(uint256 availableAssets, uint256 currentRate, uint256 maxRequestId)
        internal
        returns (uint256 finalizedAmount, uint256 finalizedCount)
    {
        // Zero-amount short circuit; not a timestamp concern.
        // slither-disable-next-line timestamp,incorrect-equality
        if (availableAssets == 0) return (0, 0);

        uint256 queued = pendingWithdrawalAssets;
        // No pending requests; not a timestamp concern.
        // slither-disable-next-line timestamp,incorrect-equality
        if (queued == 0) return (0, 0);

        uint256 requestTail = _nextRequestId;
        uint256 upperBound = maxRequestId < requestTail ? maxRequestId : requestTail;

        uint256 currentId = _nextPendingId;
        uint256 available = availableAssets;
        uint256 pendingAssets = queued;
        uint256 pendingShares_ = pendingWithdrawalShares;
        uint256 totalAdjusted;

        while (currentId < upperBound) {
            if (gasleft() < _FINALIZE_GAS_THRESHOLD) {
                break;
            }
            WithdrawalRequest storage request = _requests[currentId];
            if (!request.finalized) {
                uint256 assetsExpected = request.assetsExpected;

                // Adjust payout when slashing has reduced the exchange rate below the locked rate.
                // The > 1 tolerance accounts for floor-rounding differences between the gross rate
                // (computed on aggregate state) and per-request rates.
                if (currentRate < request.rate && request.rate - currentRate > _SLASHING_RATE_TOLERANCE) {
                    uint256 payout = (request.shares * currentRate) / _RATE_SCALE;
                    if (payout < assetsExpected) {
                        // Check liquidity against the ADJUSTED payout before any storage write.
                        if (available < payout) {
                            break;
                        }
                        uint256 adjustment = assetsExpected - payout;
                        pendingAssets -= adjustment;
                        totalAdjusted += adjustment;
                        request.assetsExpected = payout;
                        assetsExpected = payout;
                        emit WithdrawalAdjusted(currentId, assetsExpected + adjustment, assetsExpected);
                    }
                }

                // Slashing reduced payout to zero; finalize without consuming liquidity but
                // count the request — `finalizedCount` is the count of finalized requests,
                // which includes zero-payout slashes. (Audit L-27: previously the count was
                // not incremented here and the post-loop bidirectional invariant relied on
                // that omission; both have been corrected.)
                if (assetsExpected == 0) {
                    pendingShares_ -= request.shares;
                    request.finalized = true;
                    _claimableShares[_requestOwners[currentId]] += request.shares;
                    ++finalizedCount;
                    emit WithdrawalRequestFinalized(currentId, 0);
                    ++currentId;
                    continue;
                }

                // Breaks on first under-funded non-adjusted request; does not skip.
                if (available < assetsExpected) {
                    break;
                }

                available -= assetsExpected;
                finalizedAmount += assetsExpected;
                pendingAssets -= assetsExpected;
                pendingShares_ -= request.shares;
                request.finalized = true;
                _claimableShares[_requestOwners[currentId]] += request.shares;
                ++finalizedCount;
                emit WithdrawalRequestFinalized(currentId, assetsExpected);
            }

            ++currentId;
        }

        pendingWithdrawalAssets = pendingAssets;
        pendingWithdrawalShares = pendingShares_;
        _nextPendingId = SafeCast.toUint64(currentId);

        if (queued - pendingAssets != finalizedAmount + totalAdjusted) {
            // Defensive — would only trigger from a future code change that breaks the
            // pendingAssets bookkeeping above.
            revert OllaVault__FinalizeInconsistent(finalizedAmount + totalAdjusted, queued - pendingAssets);
        }

        uint256 buffered = _bufferedAssets;
        if (finalizedAmount > buffered) {
            revert OllaVault__InsufficientBufferedAssets(finalizedAmount, buffered);
        }

        // Consistency invariant: any liquidity consumed must correspond to at least one finalized
        // request. The reverse is not true after L-27: a batch of all-slashed-to-zero requests
        // legitimately finalizes with count > 0 and amount == 0.
        // slither-disable-next-line incorrect-equality
        if (finalizedAmount > 0 && finalizedCount == 0) {
            revert OllaVault__FinalizeInconsistent(finalizedAmount, finalizedCount);
        }

        // Nothing materially happened (no liquidity moved, no slashing adjustment); short circuit
        // before mutating buffered/cumulative state. We may still have advanced `_nextPendingId`
        // and finalized zero-payout slashes — those writes were already committed above.
        // slither-disable-next-line incorrect-equality
        if (finalizedAmount == 0 && totalAdjusted == 0) return (0, finalizedCount);

        if (finalizedAmount > 0) {
            _bufferedAssets = buffered - finalizedAmount;
            _finalizedUnclaimedAssets += finalizedAmount;
        }

        // Track slashing adjustments separately to preserve cumulativeWithdrawals monotonicity.
        if (totalAdjusted > 0) {
            cumulativeSlashingAdjustments += totalAdjusted;
        }

        emit WithdrawalFinalized(availableAssets, finalizedAmount);
        return (finalizedAmount, finalizedCount);
    }

    // slither-disable-end cyclomatic-complexity,pess-multiple-storage-read
    // solhint-enable function-max-lines

    /// @notice Validates deposit preconditions (safety module, cap) and computes shares.
    /// @param caller The depositor address.
    /// @param assets The amount of assets to deposit.
    /// @param recipient The receiver of the minted shares.
    /// @return shares The amount of shares minted.
    function _deposit(address caller, uint256 assets, address recipient) internal returns (uint256 shares) {
        if (recipient == address(0)) revert OllaVault__ZeroAddress("recipient");
        if (assets == 0) revert OllaVault__InvalidAmount();

        ISafetyModule sm = ISafetyModule(_safetyModule());
        if (sm.isDepositPaused()) revert OllaVault__SafetyModulePaused();
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

    /// @notice Internal helper for `mint`: converts shares to assets, validates safety
    ///         caps, and processes the deposit. Shared by the standard ERC-4626 mint
    ///         and the slippage-protected overload.
    /// @param caller The address providing the assets.
    /// @param shares The exact amount of shares to mint.
    /// @param receiver The recipient of the minted shares.
    /// @return assets The amount of underlying assets deposited.
    function _mintShares(address caller, uint256 shares, address receiver) internal returns (uint256 assets) {
        if (receiver == address(0)) revert OllaVault__ZeroAddress("receiver");
        if (shares == 0) revert OllaVault__InvalidAmount();

        ISafetyModule sm = ISafetyModule(_safetyModule());
        if (sm.isDepositPaused()) revert OllaVault__SafetyModulePaused();
        _syncBufferedWithBalance();

        IOllaCore coreRef = IOllaCore(_modules.core);
        assets = coreRef.convertToAssetsCeil(shares);

        uint256 currentTotalAssets = coreRef.totalAssets();
        if (!sm.checkDepositAllowed(assets, currentTotalAssets)) {
            revert OllaVault__DepositCapExceeded(assets, currentTotalAssets);
        }

        _processDeposit(caller, assets, shares, receiver);
        return assets;
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
        // L-11: a deposit that mints fewer shares than the current `withdrawalMinimum`
        // would land the user in a state with no exit path — async redeem and instant
        // redeem both gate on the same minimum. Mirror the exit-side check on entry.
        ISafetyModule(_safetyModule()).checkWithdrawalMinimum(shares);

        VaultModules memory modules = _modules;
        modules.asset.safeTransferFrom(caller, address(this), assets);
        _bufferedAssets += assets;
        _syncBufferedWithBalance();
        cumulativeDeposits += assets;

        modules.stAztec.mint(recipient, shares);
        emit Deposit(caller, recipient, assets, shares);
    }

    /// @notice Executes the shared logic for all async redemption paths.
    /// @param shareOwner Address whose stAztec shares are burned.
    /// @param controller Address that owns the withdrawal request (also the default claim receiver).
    /// @param shares The amount of shares to redeem.
    /// @param sharesPulledToVault True when shares were already transferred to the vault
    ///        (permit paths use safeTransferFrom to consume the allowance).
    /// @return requestId The withdrawal request id.
    /// @return assetsExpected The expected asset amount for the redeemed shares.
    function _executeRedeemRequest(address shareOwner, address controller, uint256 shares, bool sharesPulledToVault)
        internal
        returns (uint256 requestId, uint256 assetsExpected)
    {
        if (shares == 0) revert OllaVault__InvalidAmount();

        VaultModules memory modules = _modules;
        IOllaCore coreRef = IOllaCore(modules.core);

        uint256 rate = coreRef.exchangeRate();
        assetsExpected = coreRef.convertToAssets(shares);
        ISafetyModule(_safetyModule()).checkWithdrawalMinimum(shares);

        // Effects: persist the request and aggregate counters before any external call. CEI keeps
        // the contract in a consistent state if the trusted stAztec.burn ever transitions to a
        // hookful implementation; today it cannot reenter due to nonReentrant on the entrypoints.
        requestId = _nextRequestId;
        _nextRequestId = SafeCast.toUint64(requestId + 1);

        _requests[requestId] =
            WithdrawalRequest({ finalized: false, shares: shares, assetsExpected: assetsExpected, rate: rate });

        _requestOwners[requestId] = controller;
        _ownerRequestIndex[requestId] = _ownerRequestIds[controller].length + 1;
        _ownerRequestIds[controller].push(requestId);

        pendingWithdrawalAssets += assetsExpected;
        pendingWithdrawalShares += shares;
        cumulativeWithdrawals += assetsExpected;

        // Interactions: burn happens after state is settled.
        // Permit paths pull shares to vault via safeTransferFrom before calling this function,
        // so burn from vault's balance. Non-permit paths burn directly from the share owner.
        modules.stAztec.burn(sharesPulledToVault ? address(this) : shareOwner, shares);

        emit WithdrawalRequested(requestId, controller, shares, assetsExpected, rate);
        return (requestId, assetsExpected);
    }

    // slither-disable-start pess-multiple-storage-read
    // Single request struct accessed for multiple fields then deleted; caching is not applicable.
    /// @dev Claims a withdrawal request. If receiverOverride is address(0), uses the request's owner.
    ///      Storage is deleted on success, so a second claim of the same id falls through the
    ///      `requestOwnerAddr == address(0)` check and reverts with `OllaVault__RequestNotFound`.
    ///      A dedicated `AlreadyClaimed` revert path was deliberately retired in audit cleanup #357
    ///      so integrators don't have to catch a separate revert reason for the second-claim case.
    function _claimWithdrawal(uint256 requestId, address receiverOverride) internal returns (uint256 assets) {
        WithdrawalRequest storage request = _requests[requestId];
        address requestOwnerAddr = _requestOwners[requestId];
        if (requestOwnerAddr == address(0)) revert OllaVault__RequestNotFound(requestId);
        if (!request.finalized) revert OllaVault__NotFinalized(requestId);

        address receiver = receiverOverride == address(0) ? requestOwnerAddr : receiverOverride;
        assets = request.assetsExpected;
        uint256 sharesClaimed = request.shares;

        _claimableShares[requestOwnerAddr] -= sharesClaimed;
        _removeOwnerRequest(requestOwnerAddr, requestId);
        delete _requestOwners[requestId];
        delete _requests[requestId];

        _finalizedUnclaimedAssets -= assets;
        _modules.asset.safeTransfer(receiver, assets);
        emit WithdrawalClaimed(requestId, receiver, assets);
        return assets;
    }

    // slither-disable-end pess-multiple-storage-read

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
        for (uint256 i = 0; i < len; ++i) {
            uint256 id = requestIds[i];
            WithdrawalRequest storage req = _requests[id];
            if (req.finalized && req.shares == shares) {
                return id;
            }
        }
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
