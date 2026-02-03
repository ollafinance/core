// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {AccessControlUpgradeable} from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20Permit} from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@oz/utils/math/Math.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@oz/utils/ReentrancyGuard.sol";
import {IOllaCore} from "src/core/interfaces/IOllaCore.sol";
import {IRewardsVault} from "src/core/interfaces/IRewardsVault.sol";
import {IStAztec} from "src/core/interfaces/IStAztec.sol";
import {IWithdrawalQueue} from "src/core/interfaces/IWithdrawalQueue.sol";
import {ISafetyModule} from "src/safetymodule/ISafetyModule.sol";
import {RolesLib} from "src/shared/RolesLib.sol";
import {IStakingManager} from "src/staking/interfaces/IStakingManager.sol";

/// @title OllaCore
/// @notice Core vault handling deposits and async withdrawals.
/// @author Olla Core contributors
contract OllaCore is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IOllaCore
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    enum Bucket {
        Buffered,
        StakedPrincipal,
        RewardsVault,
        RewardsDelta,
        SlashingDelta
    }

    uint256 private constant _EXCHANGE_RATE_SCALE = 1e18;

    /// @notice Role for guardian pause/unpause actions.
    bytes32 public constant GUARDIAN_ROLE = RolesLib.GUARDIAN_ROLE;
    /// @notice Role for operator accounting actions.
    bytes32 public constant OPERATOR_ROLE = RolesLib.OPERATOR_ROLE;

    /// @notice Basis points divisor.
    uint256 public constant BP_DIVISOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract related interfaces and addresses
    IOllaCore.Modules private _modules;

    /// @notice Accounting and reporting values
    IOllaCore.AccountingState private _accountingState;
    IOllaCore.FlowCounters private _flowCounters;
    IOllaCore.LatestReport private _latestReport;

    /// @notice The protocol fee in basis points.
    uint256 public protocolFeeBP;

    /// @notice The treasury fee split in basis points.
    uint256 public treasuryFeeSplitBP;

    /// @notice Threshold to trigger unit-based unstaking.
    uint256 public unstakeThreshold;

    mapping(address owner => uint256 requestId) private _activeRequestIds;
    mapping(uint256 requestId => address owner) private _requestOwners;

    /// @notice Storage gap for upgradability
    // slither-disable-next-line unused-state
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a caller is not governance.
    error OllaCore__UnauthorizedGovernance(address caller);

    /// @notice Thrown when a bucket lacks sufficient balance.
    error OllaCore__InsufficientBucketBalance(Bucket bucket, uint256 amount, uint256 available);

    /// @notice Thrown when buffered assets do not match the vault balance.
    error OllaCore__BufferedBalanceMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when queue assets do not match stored request data.
    error OllaCore__ClaimAssetsMismatch(uint256 requestId, uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaCore
    function initialize(
        IERC20 asset_,
        IStAztec stAztec_,
        IStakingManager stakingManager_,
        uint256 protocolFeeBP_,
        uint256 treasuryFeeSplitBP_,
        address governance_,
        address withdrawalQueue_,
        IRewardsVault rewardsVault_,
        address safetyModule_
    ) external override initializer {
        _validateInitialParams(
            asset_,
            stAztec_,
            stakingManager_,
            protocolFeeBP_,
            treasuryFeeSplitBP_,
            governance_,
            withdrawalQueue_,
            rewardsVault_,
            safetyModule_
        );
        __AccessControl_init();
        __Pausable_init();

        _modules = IOllaCore.Modules({
            asset: asset_,
            stAztec: stAztec_,
            stakingManager: stakingManager_,
            governance: governance_,
            withdrawalQueue: IWithdrawalQueue(withdrawalQueue_),
            rewardsVault: rewardsVault_,
            safetyModule: safetyModule_
        });

        protocolFeeBP = protocolFeeBP_;
        treasuryFeeSplitBP = treasuryFeeSplitBP_;
        unstakeThreshold = stakingManager_.activationThreshold();

        _latestReport.exchangeRate = _EXCHANGE_RATE_SCALE;
        // Timestamp is used only for reporting/accounting liveness.
        // slither-disable-next-line timestamp
        _latestReport.timestamp = block.timestamp;

        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, governance_);
        _grantRole(GUARDIAN_ROLE, governance_);
        _grantRole(OPERATOR_ROLE, governance_);
    }

    /// @notice Deposits assets and mints stAztec shares.
    /// @param assets The amount of assets to deposit.
    /// @param recipient The recipient of the stAztec shares.
    /// @return shares The shares minted to the recipient.
    function deposit(uint256 assets, address recipient)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        shares = _deposit(msg.sender, assets, recipient);
        return shares;
    }

    /// @notice Deposits assets with a permit signature and mints stAztec shares.
    /// @param assets The amount of assets to deposit.
    /// @param recipient The recipient of the stAztec shares.
    /// @param deadline The permit deadline timestamp.
    /// @param v The permit signature v.
    /// @param r The permit signature r.
    /// @param s The permit signature s.
    /// @return shares The shares minted to the recipient.
    function depositWithPermit(uint256 assets, address recipient, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        IERC20Permit(address(_modules.asset)).permit(msg.sender, address(this), assets, deadline, v, r, s);
        shares = _deposit(msg.sender, assets, recipient);
        return shares;
    }

    /// @notice Requests a redemption in shares.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the assets.
    /// @return requestId The withdrawal request id.
    function requestRedeem(uint256 shares, address recipient)
        external
        override
        nonReentrant
        returns (uint256 requestId)
    {
        requestId = _requestRedeem(msg.sender, shares, recipient);
        return requestId;
    }

    /// @notice Requests a redemption in shares with a permit signature.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the assets.
    /// @param deadline The permit deadline timestamp.
    /// @param v The permit signature v.
    /// @param r The permit signature r.
    /// @param s The permit signature s.
    /// @return requestId The withdrawal request id.
    function requestRedeemWithPermit(uint256 shares, address recipient, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
        nonReentrant
        returns (uint256 requestId)
    {
        // slither-disable-next-line reentrancy-benign
        _modules.stAztec.permit(msg.sender, address(this), shares, deadline, v, r, s);
        requestId = _requestRedeem(msg.sender, shares, recipient);
        return requestId;
    }

    /// @notice Claims a finalized withdrawal request for a controller.
    /// @param owner The request owner.
    /// @return assets The assets claimed for the request.
    function claimActiveRequest(address owner) external override nonReentrant returns (uint256 assets) {
        uint256 requestId = _activeRequestIds[owner];
        assets = _claimWithdrawal(requestId);
        return assets;
    }

    /// @notice Claims a finalized withdrawal request by id.
    /// @param requestId The withdrawal request id.
    /// @return assets The assets claimed for the request.
    function claimRequestById(uint256 requestId) external override nonReentrant returns (uint256 assets) {
        assets = _claimWithdrawal(requestId);
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                      PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses deposits and withdrawals.
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        _pause();
        emit Paused();
    }

    /// @notice Unpauses deposits and withdrawals.
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        _unpause();
        emit Unpaused();
    }

    /// @notice Sets the protocol fee in basis points.
    /// @param newFeeBP The new fee (0-10000).
    function setProtocolFeeBP(uint256 newFeeBP) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBP > BP_DIVISOR) {
            revert OllaCore__InvalidFeeBP(newFeeBP);
        }
        uint256 oldFeeBP = protocolFeeBP;
        protocolFeeBP = newFeeBP;
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);
    }

    /// @notice Sets the treasury fee split in basis points.
    /// @param newSplitBP The new split (0-10000).
    function setTreasuryFeeSplitBP(uint256 newSplitBP) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSplitBP > BP_DIVISOR) {
            revert OllaCore__InvalidSplitBP(newSplitBP);
        }
        uint256 oldSplitBP = treasuryFeeSplitBP;
        treasuryFeeSplitBP = newSplitBP;
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);
    }

    /// @notice Sets the governance address.
    /// @param newGovernance The new governance address.
    function setGovernance(address newGovernance) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newGovernance == address(0)) {
            revert OllaCore__ZeroAddress("newGovernance");
        }
        address oldGovernance = _modules.governance;
        _modules.governance = newGovernance;

        // Transfer governance-related roles from the old governance to the new one
        if (newGovernance != oldGovernance) {
            // Grant roles to the new governance address first (before revoking from old)
            _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, newGovernance);
            _grantRole(GUARDIAN_ROLE, newGovernance);
            _grantRole(OPERATOR_ROLE, newGovernance);

            // Revoke roles from the old governance address
            if (oldGovernance != address(0)) {
                _revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
                _revokeRole(GUARDIAN_ROLE, oldGovernance);
                _revokeRole(OPERATOR_ROLE, oldGovernance);
            }
        }
        emit GovernanceUpdated(oldGovernance, newGovernance);
    }

    /// @notice Sets the rewards vault address.
    /// @param newRewardsVault The new rewards vault address.
    function setRewardsVault(IRewardsVault newRewardsVault) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newRewardsVault) == address(0)) {
            revert OllaCore__ZeroAddress("newRewardsVault");
        }
        IRewardsVault oldRewardsVault = _modules.rewardsVault;
        _modules.rewardsVault = newRewardsVault;
        emit RewardsVaultUpdated(address(oldRewardsVault), address(newRewardsVault));
    }

    /// @notice Sets the unstake threshold used to trigger unit-based unstaking.
    /// @param newThreshold The new unstake threshold.
    function setUnstakeThreshold(uint256 newThreshold) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 activationThreshold = _modules.stakingManager.activationThreshold();
        if (newThreshold == 0 || newThreshold > activationThreshold) {
            revert OllaCore__InvalidUnstakeThreshold(newThreshold, activationThreshold);
        }
        uint256 oldThreshold = unstakeThreshold;
        unstakeThreshold = newThreshold;
        emit UnstakeThresholdUpdated(oldThreshold, newThreshold);
    }

    /// @notice Operator-triggered rebalance flow.
    /// @dev Executes: harvest -> pull unstaked -> finalize withdrawals -> initiate unstake -> stake surplus
    function rebalance() external override onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        _syncBufferedWithBalance();
        // Slither: rebalance is nonReentrant and uses trusted modules for external calls.
        // slither-disable-next-line reentrancy-no-eth
        uint256 rewardsDelta = _harvestRewards();

        _pullUnstakedFunds();

        uint256 finalizedAmount = _finalizeWithdrawals();

        _initiateUnstake();

        // TODO: Phase 5 - Stake surplus
        uint256 stakedAmount = 0;

        emit Rebalanced(rewardsDelta, finalizedAmount, stakedAmount, _accountingState.bufferedAssets);
    }

    // Slither: accept multiple storage reads for readability in hot-path accounting.
    // Slither: accept multiple storage reads for readability in withdrawal finalization.
    // slither-disable-start pess-multiple-storage-read
    // solhint-disable function-max-lines
    /// @notice Updates accounting snapshots and publishes the latest exchange rate data.
    function updateAccounting() external override onlyRole(OPERATOR_ROLE) nonReentrant {
        ISafetyModule safetyModuleRef = ISafetyModule(_modules.safetyModule);
        // slither-disable-start reentrancy-no-eth
        // slither-disable-start reentrancy-benign
        // slither-disable-start reentrancy-events
        // SafetyModule is a trusted dependency; updateAccounting is nonReentrant and role-gated, so
        // fail-fast checks before accounting updates are safe.
        safetyModuleRef.checkAccountingLiveness();

        (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows) = _getFlowsSnapshot();
        (
            uint256 currentRewards,
            uint256 rewardsDelta,
            uint256 slashingDelta,
            uint256 stakedPrincipal,
            uint256 claimableRewards
        ) = _getStakingManagerState();
        _validateSlashingDelta(slashingDelta);

        uint256 rewardsVaultBalance = _getRewardsVaultBalance();

        _applyAccountingUpdates(stakedPrincipal, rewardsVaultBalance, claimableRewards, rewardsDelta, slashingDelta);

        _computeAndFinalizeAccounting(safetyModuleRef, flowsSnapshot, netFlows, currentRewards);
        // slither-disable-end reentrancy-events
        // slither-disable-end reentrancy-benign
        // slither-disable-end reentrancy-no-eth
    }

    // solhint-enable function-max-lines

    // slither-disable-end pess-multiple-storage-read

    /// @notice Reconciles buffered assets with the actual asset balance.
    /// @return delta The amount added to buffered assets.
    function reconcileBufferedAssets() external override onlyRole(OPERATOR_ROLE) returns (uint256 delta) {
        delta = _reconcileBufferedAssets(address(this));
        return delta;
    }

    /// @notice Recovers stAztec sent directly to the core.
    /// @param recipient The recipient of the recovered stAztec (defaults to governance if zero).
    /// @param amount The amount of stAztec to recover.
    function recoverStAztec(address recipient, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        address resolvedRecipient = recipient == address(0) ? _modules.governance : recipient;
        IERC20(address(_modules.stAztec)).safeTransfer(resolvedRecipient, amount);
        emit StAztecRecovered(amount, resolvedRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the underlying asset address.
    /// @return The underlying asset address.
    function asset() external view override returns (address) {
        return address(_modules.asset);
    }

    /// @notice Returns the stAztec share token address.
    /// @return The stAztec share token address.
    function stAztec() external view override returns (address) {
        return address(_modules.stAztec);
    }

    /// @notice Returns the staking manager address.
    /// @return The staking manager address.
    function stakingManager() external view override returns (address) {
        return address(_modules.stakingManager);
    }

    /// @notice Returns the active withdrawal request id for an owner.
    /// @param owner The request owner.
    /// @return requestId The active request id or zero if none.
    function activeRequestId(address owner) external view override returns (uint256 requestId) {
        return _activeRequestIds[owner];
    }

    /// @notice Returns the recorded owner for a withdrawal request id.
    /// @param requestId The withdrawal request id.
    /// @return owner The request owner.
    function requestOwner(uint256 requestId) external view override returns (address owner) {
        return _requestOwners[requestId];
    }

    /// @notice Returns the active withdrawal request for an owner.
    /// @param owner The request owner.
    /// @return request The withdrawal request struct.
    function getActiveWithdrawalRequest(address owner)
        external
        view
        override
        returns (IWithdrawalQueue.WithdrawalRequest memory request)
    {
        uint256 requestId = _activeRequestIds[owner];
        if (requestId == 0) {
            revert IOllaCore.OllaCore__NoActiveWithdrawal(owner);
        }
        return _modules.withdrawalQueue.getRequest(requestId);
    }

    /// @notice Returns the governance address.
    /// @return The governance address.
    function governance() external view override returns (address) {
        return _modules.governance;
    }

    /// @notice Returns the withdrawal queue module address.
    /// @return The withdrawal queue address.
    function withdrawalQueue() external view override returns (address) {
        return address(_modules.withdrawalQueue);
    }

    /// @notice Returns the rewards vault module address.
    /// @return The rewards vault address.
    function rewardsVault() external view override returns (address) {
        return address(_modules.rewardsVault);
    }

    /// @notice Returns the safety module address.
    /// @return The safety module address.
    function safetyModule() external view override returns (address) {
        return _modules.safetyModule;
    }

    /// @notice Returns the latest accounting report snapshot.
    /// @return The latest report struct.
    function latestReport() external view override returns (IOllaCore.LatestReport memory) {
        return _latestReport;
    }

    /// @notice Returns the flow counter snapshots.
    /// @return The flow counters struct.
    function flowCounters() external view override returns (IOllaCore.FlowCounters memory) {
        return _flowCounters;
    }

    /// @notice Returns the accounting buckets snapshot.
    /// @return The accounting state struct.
    function accountingState() external view override returns (IOllaCore.AccountingState memory) {
        return _accountingState;
    }

    /// @notice Returns the current exchange rate in 18-decimal fixed-point units.
    /// @return The exchange rate scaled by 1e18.
    function exchangeRate() external view override returns (uint256) {
        return _exchangeRate();
    }

    /// @notice Computes the shares for an asset amount.
    /// @param assets The asset amount being converted.
    /// @return shares The shares that would be minted.
    /// Formula: assets * totalSupply / totalAssets (floor), assets if supply == 0.
    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Computes the assets for a share amount.
    /// @param shares The share amount being converted.
    /// @return assets The assets that would be returned.
    /// Formula: shares * totalAssets / totalSupply (floor), shares if supply == 0.
    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        IStAztec stAztecToken = _modules.stAztec;
        uint256 supply = stAztecToken.totalSupply();
        if (supply == 0) {
            return shares;
        }
        assets = shares.mulDiv(totalAssets(), supply, Math.Rounding.Floor);
        return assets;
    }

    /// @notice Returns the shares previewed for a deposit.
    /// @param assets The asset amount being deposited.
    /// @return shares The shares that would be minted.
    function previewDeposit(uint256 assets) external view override returns (uint256 shares) {
        return _convertToSharesForDeposit(assets);
    }

    /// @notice Returns the current total assets held by the vault.
    /// @return The total assets held by the vault.
    function totalAssets() public view override returns (uint256) {
        IOllaCore.AccountingState storage buckets = _accountingState;
        return buckets.bufferedAssets + buckets.stakedPrincipal + buckets.rewardsVaultBalance + buckets.claimableRewards
            - buckets.slashingDelta;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address caller, uint256 assets, address recipient) internal returns (uint256 shares) {
        if (recipient == address(0)) {
            revert OllaCore__ZeroAddress("recipient");
        }

        Modules memory modules = _modules;

        if (ISafetyModule(modules.safetyModule).isPaused()) {
            revert OllaCore__SafetyModulePaused();
        }

        _syncBufferedWithBalance();

        uint256 currentTotalAssets = totalAssets();
        if (!ISafetyModule(modules.safetyModule).checkDepositAllowed(assets, currentTotalAssets)) {
            revert OllaCore__DepositCapExceeded(assets, currentTotalAssets);
        }

        shares = _convertToSharesForDeposit(assets);
        _increaseBuffered(assets);
        modules.asset.safeTransferFrom(caller, address(this), assets);
        _syncBufferedWithBalance();
        _increaseCumulativeDeposits(assets);

        modules.stAztec.mint(recipient, shares);
        emit Deposit(caller, recipient, assets, shares);
        return shares;
    }

    function _harvestRewards() internal returns (uint256 rewardsDelta) {
        // Trigger the actual claiming on the rollup (rewards are sent directly to RewardsVault)
        // We intentionally ignore the return value because rewards may be permissionlessly harvested.
        // The actual amount received is determined by delta from RewardsVault.recordBalance().
        // slither-disable-next-line unused-return
        _modules.stakingManager.harvestRewards();

        // Get the actual delta from RewardsVault and update cumulative rewards
        // slither-disable-next-line reentrancy-benign
        rewardsDelta = _modules.rewardsVault.recordBalance();
        if (rewardsDelta != 0) {
            _accountingState.cumulativeRewards += rewardsDelta;
        }
        emit RewardsDelta(rewardsDelta);
        return rewardsDelta;
    }

    /// @notice Pulls unstaked funds from the staking manager.
    /// @return receivedAmount The amount of unstaked funds received.
    function _pullUnstakedFunds() internal returns (uint256 receivedAmount) {
        IERC20 assetRef = _modules.asset;
        uint256 balanceBefore = assetRef.balanceOf(address(this));

        // Slither: stakingManager is trusted; rebalance is nonReentrant and role-gated.
        // slither-disable-next-line reentrancy-benign
        receivedAmount = _modules.stakingManager.getUnstakedFunds();

        uint256 balanceAfter = assetRef.balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;

        if (receivedAmount != 0 && receivedAmount != actualReceived) {
            revert OllaCore__UnstakedFundsMismatch(receivedAmount, actualReceived);
        }

        if (actualReceived > 0) {
            _accountingState.bufferedAssets += actualReceived;
            emit UnstakedFundsClaimed(actualReceived);
        }

        return actualReceived;
    }

    /// @notice Finalizes pending withdrawal requests using available liquidity.
    /// @return finalizedAmount The amount of assets used to finalize withdrawals.
    function _finalizeWithdrawals() internal returns (uint256 finalizedAmount) {
        // Requires the caller to have reconciled buffered assets (rebalance does this via _syncBufferedWithBalance).
        uint256 bufferedAssets = _accountingState.bufferedAssets;
        uint256 availableForWithdrawals = bufferedAssets;

        // slither-disable-next-line timestamp,incorrect-equality - zero guards only, no timestamp usage
        if (availableForWithdrawals == 0) {
            return 0;
        }

        IOllaCore.Modules memory modules = _modules;
        uint256 queued = modules.withdrawalQueue.totalPendingAssets();
        uint256 total = totalAssets();
        // slither-disable-next-line reentrancy-no-eth - external calls under nonReentrant entrypoints
        ISafetyModule(modules.safetyModule).checkQueueRatio(queued, total);
        // slither-disable-next-line timestamp,incorrect-equality - zero guards only, no timestamp usage
        if (queued == 0) {
            return 0;
        }

        // slither-disable-next-line timestamp,incorrect-equality - zero guards only, no timestamp usage
        uint256 previewUsed = modules.withdrawalQueue.previewFinalizeWithdrawals(availableForWithdrawals);
        // slither-disable-next-line timestamp,incorrect-equality - zero guards only, no timestamp usage
        if (previewUsed == 0) {
            return 0;
        }

        if (previewUsed > bufferedAssets) {
            revert OllaCore__InsufficientBucketBalance(Bucket.Buffered, previewUsed, bufferedAssets);
        }

        // slither-disable-next-line reentrancy-no-eth - external call under nonReentrant entrypoints
        finalizedAmount = modules.withdrawalQueue.finalizeWithdrawals(availableForWithdrawals);
        // slither-disable-next-line timestamp,incorrect-equality - zero guards only, no timestamp usage
        if (finalizedAmount != previewUsed) {
            revert OllaCore__FinalizeAmountMismatch(previewUsed, finalizedAmount);
        }

        _decreaseBuffered(finalizedAmount);

        emit WithdrawalFinalized(availableForWithdrawals, finalizedAmount);
        return finalizedAmount;
    }

    /// @notice Initiates unstaking when pending withdrawals exceed buffered assets.
    /// @return initiated Amount actually initiated for unstake.
    // slither-disable-next-line pess-unprotected-initialize
    function _initiateUnstake() internal returns (uint256 initiated) {
        IOllaCore.Modules memory modules = _modules;
        uint256 pendingWithdrawals = modules.withdrawalQueue.totalPendingAssets();
        uint256 bufferedAssets = _accountingState.bufferedAssets;

        // slither-disable-next-line timestamp
        if (pendingWithdrawals < bufferedAssets) {
            return 0;
        }
        // slither-disable-next-line timestamp,incorrect-equality
        if (pendingWithdrawals == bufferedAssets) {
            return 0;
        }

        uint256 amountToUnstake = pendingWithdrawals - bufferedAssets;
        uint256 pendingUnstakes = modules.stakingManager.pendingUnstakes();
        // slither-disable-next-line timestamp
        if (pendingUnstakes > amountToUnstake) {
            return 0;
        }
        // slither-disable-next-line timestamp,incorrect-equality
        if (pendingUnstakes == amountToUnstake) {
            return 0;
        }

        uint256 requested = amountToUnstake - pendingUnstakes;
        uint256 threshold = unstakeThreshold;
        // slither-disable-next-line timestamp
        if (requested < threshold) {
            return 0;
        }

        uint256 activationThreshold = modules.stakingManager.activationThreshold();
        // Unstakes happen in full attester units; round down unless below one unit.
        // slither-disable-next-line timestamp
        if (requested < activationThreshold) {
            initiated = activationThreshold;
        } else {
            // Intentional floor-to-unit rounding; result <= requested so no overflow risk.
            // slither-disable-next-line divide-before-multiply
            initiated = (requested / activationThreshold) * activationThreshold;
        }

        // slither-disable-next-line timestamp
        if (initiated > 0) {
            modules.stakingManager.unstake(initiated);
            emit UnstakeInitiated(amountToUnstake, initiated);
        }

        return initiated;
    }

    function _requestRedeem(address owner, uint256 shares, address recipient) internal returns (uint256 requestId) {
        if (recipient == address(0)) {
            revert OllaCore__ZeroAddress("recipient");
        }

        if (_activeRequestIds[owner] != 0) {
            revert OllaCore__PendingWithdrawalExists(owner);
        }

        Modules memory modules = _modules;

        uint256 rate = _exchangeRate();
        uint256 assetsExpected = shares.mulDiv(rate, _EXCHANGE_RATE_SCALE, Math.Rounding.Floor);
        ISafetyModule(modules.safetyModule).checkWithdrawalMinimum(shares);
        uint256 expectedRequestId = modules.withdrawalQueue.nextRequestId();

        _activeRequestIds[owner] = expectedRequestId;
        _requestOwners[expectedRequestId] = owner;
        _increaseCumulativeWithdrawals(assetsExpected);
        modules.stAztec.burn(owner, shares);

        requestId = modules.withdrawalQueue.requestWithdrawal(recipient, shares, assetsExpected, rate);
        if (requestId != expectedRequestId) {
            revert OllaCore__UnexpectedRequestId(expectedRequestId, requestId);
        }

        emit WithdrawalRequested(requestId, recipient, shares, assetsExpected, rate);
        return requestId;
    }

    /// @notice Payout protocol fees through minting shares.
    /// @param grossAssetRewards The gross asset rewards to charge fees on.
    /// @return ollaProtocolFeeAssets The asset amount paid as protocol fees.
    /// @return treasuryShares The shares minted to the treasury.
    /// @return providerShares The shares minted to the provider.
    function _payoutOllaProtocolFees(uint256 grossAssetRewards)
        internal
        onlyRole(OPERATOR_ROLE)
        returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        //Rationale: strict equality here is intentional and safe for unsigned values;
        //timestamp detector is inapplicable because no timestamp is used.
        // slither-disable-next-line incorrect-equality,timestamp
        if (grossAssetRewards == 0 || protocolFeeBP == 0 || totalAssets() == 0) {
            return (0, 0, 0);
        }
        Modules memory modules = _modules;
        (ollaProtocolFeeAssets, treasuryShares, providerShares) = _calculateProtocolFees(grossAssetRewards);
        emit OllaProtocolFeesPaid(ollaProtocolFeeAssets, treasuryShares, providerShares);
        modules.stAztec.mint(modules.governance, treasuryShares);
        address providerRewardsRecipient = modules.stakingManager.getProviderConfig().rewardsRecipient;
        modules.stAztec.mint(providerRewardsRecipient, providerShares);

        return (ollaProtocolFeeAssets, treasuryShares, providerShares);
    }

    function _claimWithdrawal(uint256 requestId) internal returns (uint256 assets) {
        IWithdrawalQueue queue = _modules.withdrawalQueue;
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        address receiver = request.recipient;
        assets = request.assetsExpected;
        address owner = _requestOwners[requestId];
        if (owner != address(0)) {
            _activeRequestIds[owner] = 0;
            delete _requestOwners[requestId];
        }

        uint256 assetsClaimed = queue.claimWithdrawal(requestId);
        if (assetsClaimed != assets) {
            revert OllaCore__ClaimAssetsMismatch(requestId, assets, assetsClaimed);
        }

        _modules.asset.safeTransfer(receiver, assets);
        emit WithdrawalClaimed(requestId, receiver, assets);
        return assets;
    }

    function _increaseCumulativeDeposits(uint256 amount) internal {
        _flowCounters.cumulativeDeposits += amount;
    }

    function _increaseCumulativeWithdrawals(uint256 amount) internal {
        _flowCounters.cumulativeWithdrawals += amount;
    }

    // Slither: using storage refs is clearer for snapshot update.
    // slither-disable-next-line pess-multiple-storage-read
    function _updateReportingSnapshots(
        uint256 total,
        uint256 rate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 updatedCumulativeDeposits,
        uint256 updatedCumulativeWithdrawals,
        uint256 rewardsSnapshot
    ) internal {
        IOllaCore.LatestReport storage report = _latestReport;
        report.totalAssets = total;
        report.exchangeRate = rate;
        report.grossRewards = grossRewards;
        report.netFlows = netFlows;
        report.rewardsSnapshot = rewardsSnapshot;

        // Timestamp is used only for reporting/accounting liveness.
        // slither-disable-next-line timestamp
        report.timestamp = block.timestamp;

        IOllaCore.FlowCounters storage flows = _flowCounters;
        flows.latestReportCumulativeDeposits = updatedCumulativeDeposits;
        flows.latestReportCumulativeWithdrawals = updatedCumulativeWithdrawals;
    }

    // Slither: storage updates are grouped for clarity.
    // slither-disable-next-line pess-multiple-storage-read
    function _applyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsVaultBalance,
        uint256 newClaimableRewards,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) internal {
        IOllaCore.AccountingState storage stateSnapshot = _accountingState;
        stateSnapshot.stakedPrincipal = newStakedPrincipal;
        stateSnapshot.rewardsVaultBalance = newRewardsVaultBalance;
        stateSnapshot.claimableRewards = newClaimableRewards;
        stateSnapshot.rewardsDelta = newRewardsDelta;
        stateSnapshot.slashingDelta = newSlashingDelta;
    }

    function _increaseBuffered(uint256 amount) internal {
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        uint256 oldValue = _accountingState.bufferedAssets;
        uint256 newValue = oldValue + amount;
        _accountingState.bufferedAssets = newValue;
    }

    function _decreaseBuffered(uint256 amount) internal {
        // slither-disable-next-line timestamp,incorrect-equality - zero guard only, no timestamp usage
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        _accountingState.bufferedAssets -= amount;
    }

    function _getStakingManagerState()
        internal
        returns (
            uint256 currentRewards,
            uint256 rewardsDelta,
            uint256 slashingDelta,
            uint256 stakedPrincipal,
            uint256 claimableRewards
        )
    {
        IOllaCore.Modules memory modules = _modules;
        IOllaCore.AccountingState memory accountingSnapshot = _accountingState;
        claimableRewards = modules.stakingManager.getClaimableRewards();
        currentRewards = accountingSnapshot.cumulativeRewards + claimableRewards;

        uint256 latestReportRewards = _latestReport.rewardsSnapshot;
        // Clamp signed delta; no timestamp-based control flow.
        // slither-disable-next-line timestamp
        int256 rewardsDeltaSigned = SafeCast.toInt256(currentRewards) - SafeCast.toInt256(latestReportRewards);
        // slither-disable-next-line timestamp
        // Defensive: currentRewards should be non-decreasing, but clamp if a downstream module reports a drop.
        // slither-disable-next-line timestamp
        if (rewardsDeltaSigned > 0) {
            rewardsDelta = SafeCast.toUint256(rewardsDeltaSigned);
        }
        slashingDelta = modules.stakingManager.getSlashingDelta();
        stakedPrincipal = modules.stakingManager.totalStaked();
        return (currentRewards, rewardsDelta, slashingDelta, stakedPrincipal, claimableRewards);
    }

    function _computeAndFinalizeAccounting(
        ISafetyModule safetyModuleRef,
        IOllaCore.FlowCounters memory flowsSnapshot,
        int256 netFlows,
        uint256 currentRewards
    ) internal {
        (uint256 oldTotalAssets, uint256 oldRate) = _getLatestReport();
        // Slither: external calls (stAztec mint + safety module) are trusted and guarded by nonReentrant entrypoints.
        // slither-disable-next-line reentrancy-no-eth
        // slither-disable-next-line reentrancy-benign
        (
            IOllaCore.AccountingState memory updatedBuckets,
            uint256 newTotalAssets,
            uint256 grossRewards,
            uint256 protocolFeeAssets,
            uint256 treasuryShares,
            uint256 providerShares,
            uint256 rate
        ) = _computeAccountingOutputs(oldTotalAssets, netFlows);

        IOllaCore.Modules memory modules = _modules;
        uint256 queued = modules.withdrawalQueue.totalPendingAssets();
        // slither-disable-next-line reentrancy-no-eth
        safetyModuleRef.checkQueueRatio(queued, newTotalAssets);
        _validateRateDrop(safetyModuleRef, oldRate, rate);
        _updateReportingSnapshots(
            newTotalAssets,
            rate,
            grossRewards,
            netFlows,
            flowsSnapshot.cumulativeDeposits,
            flowsSnapshot.cumulativeWithdrawals,
            currentRewards
        );
        _updateAccountingTimestamp(safetyModuleRef);
        _emitAccountingReport(
            updatedBuckets,
            newTotalAssets,
            rate,
            grossRewards,
            netFlows,
            protocolFeeAssets,
            treasuryShares,
            providerShares
        );
    }

    function _computeAccountingOutputs(uint256 oldTotalAssets, int256 netFlows)
        internal
        returns (
            IOllaCore.AccountingState memory updatedBuckets,
            uint256 newTotalAssets,
            uint256 grossRewards,
            uint256 protocolFeeAssets,
            uint256 treasuryShares,
            uint256 providerShares,
            uint256 rate
        )
    {
        updatedBuckets = _accountingState;
        newTotalAssets = _computeTotalAssets(updatedBuckets);
        grossRewards = _computeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        (protocolFeeAssets, treasuryShares, providerShares) = _payoutOllaProtocolFees(grossRewards);
        rate = _exchangeRate();
        return (updatedBuckets, newTotalAssets, grossRewards, protocolFeeAssets, treasuryShares, providerShares, rate);
    }

    function _validateRateDrop(ISafetyModule safetyModuleRef, uint256 oldRate, uint256 rate) internal {
        safetyModuleRef.checkRateDrop(oldRate, rate);
    }

    function _updateAccountingTimestamp(ISafetyModule safetyModuleRef) internal {
        // Timestamp is used only for reporting/accounting liveness.
        // slither-disable-next-line timestamp
        safetyModuleRef.setLatestAccountingTimestamp(block.timestamp);
    }

    function _emitAccountingReport(
        IOllaCore.AccountingState memory updatedBuckets,
        uint256 newTotalAssets,
        uint256 rate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares
    ) internal {
        emit AttestersStateRead(updatedBuckets.rewardsDelta, updatedBuckets.slashingDelta, _latestReport.timestamp);
        emit AccountingUpdated(
            newTotalAssets,
            rate,
            grossRewards,
            netFlows,
            protocolFeeAssets,
            treasuryShares,
            providerShares,
            _latestReport.timestamp
        );
    }

    function _reconcileBufferedAssets(address recipient) internal returns (uint256 delta) {
        uint256 buffered = _accountingState.bufferedAssets;
        uint256 actual = _modules.asset.balanceOf(address(this));
        // slither-disable-next-line timestamp
        if (actual < buffered) {
            revert OllaCore__BufferedBalanceMismatch(buffered, actual);
        }
        delta = actual - buffered;
        if (delta != 0) {
            _accountingState.bufferedAssets = actual;
            emit BufferedAssetsReconciled(delta, actual, recipient);
        }
        return delta;
    }

    function _syncBufferedWithBalance() internal {
        _reconcileBufferedAssets(address(this));
    }

    function _getFlowsSnapshot() internal view returns (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows) {
        flowsSnapshot = _flowCounters;
        (netFlows,,) = _computeNetFlows(flowsSnapshot);
        return (flowsSnapshot, netFlows);
    }

    function _getLatestReport() internal view returns (uint256 reportedTotalAssets, uint256 reportedExchangeRate) {
        IOllaCore.LatestReport memory report = _latestReport;
        return (report.totalAssets, report.exchangeRate);
    }

    function _getRewardsVaultBalance() internal view returns (uint256 rewardsVaultBalance) {
        return IRewardsVault(_modules.rewardsVault).balance();
    }

    function _validateSlashingDelta(uint256 slashingDelta) internal view {
        uint256 previousSlashingDelta = _accountingState.slashingDelta;
        // slither-disable-next-line timestamp
        if (slashingDelta < previousSlashingDelta) {
            revert OllaCore__InvalidSlashingDelta(previousSlashingDelta, slashingDelta);
        }
    }

    function _calculateProtocolFees(uint256 grossAssetRewards)
        internal
        view
        onlyRole(OPERATOR_ROLE)
        returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        ollaProtocolFeeAssets =
            grossAssetRewards * protocolFeeBP / BP_DIVISOR;

        uint256 protocolSharesTotal = _convertToShares(ollaProtocolFeeAssets, Math.Rounding.Floor);

        treasuryShares = protocolSharesTotal * treasuryFeeSplitBP / BP_DIVISOR;
        providerShares = protocolSharesTotal - treasuryShares;

        return (ollaProtocolFeeAssets, treasuryShares, providerShares);
    }

    function _exchangeRate() internal view returns (uint256) {
        IStAztec stAztecToken = _modules.stAztec;
        uint256 supply = stAztecToken.totalSupply();
        if (supply == 0) {
            return _EXCHANGE_RATE_SCALE;
        }
        return totalAssets().mulDiv(_EXCHANGE_RATE_SCALE, supply, Math.Rounding.Floor);
    }

    function _convertToSharesForDeposit(uint256 assets) internal view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        IStAztec stAztecToken = _modules.stAztec;
        uint256 supply = stAztecToken.totalSupply();
        if (supply == 0) {
            return assets;
        }
        return assets.mulDiv(supply, totalAssets(), rounding);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != _modules.governance) {
            revert OllaCore__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert OllaCore__ZeroAddress("newImplementation");
        }
    }

    function _validateInitialParams(
        IERC20 asset_,
        IStAztec stAztec_,
        IStakingManager stakingManager_,
        uint256 protocolFeeBP_,
        uint256 treasuryFeeSplitBP_,
        address governance_,
        address withdrawalQueue_,
        IRewardsVault rewardsVault_,
        address safetyModule_
    ) internal pure {
        if (address(asset_) == address(0)) {
            revert OllaCore__ZeroAddress("asset_");
        }
        if (address(stAztec_) == address(0)) {
            revert OllaCore__ZeroAddress("stAztec_");
        }
        if (address(stakingManager_) == address(0)) {
            revert OllaCore__ZeroAddress("stakingManager_");
        }
        if (protocolFeeBP_ > BP_DIVISOR) {
            revert OllaCore__InvalidFeeBP(protocolFeeBP_);
        }
        if (treasuryFeeSplitBP_ > BP_DIVISOR) {
            revert OllaCore__InvalidSplitBP(treasuryFeeSplitBP_);
        }
        if (governance_ == address(0)) {
            revert OllaCore__ZeroAddress("governance_");
        }
        if (withdrawalQueue_ == address(0)) {
            revert OllaCore__ZeroAddress("withdrawalQueue_");
        }
        if (address(rewardsVault_) == address(0)) {
            revert OllaCore__ZeroAddress("rewardsVault_");
        }
        if (safetyModule_ == address(0)) {
            revert OllaCore__ZeroAddress("safetyModule_");
        }
    }

    function _computeNetFlows(IOllaCore.FlowCounters memory flows)
        internal
        pure
        returns (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        netDeposits = flows.cumulativeDeposits > flows.latestReportCumulativeDeposits
            ? flows.cumulativeDeposits - flows.latestReportCumulativeDeposits
            : 0;
        netWithdrawals = flows.cumulativeWithdrawals > flows.latestReportCumulativeWithdrawals
            ? flows.cumulativeWithdrawals - flows.latestReportCumulativeWithdrawals
            : 0;
        netFlows = SafeCast.toInt256(netDeposits) - SafeCast.toInt256(netWithdrawals);
        return (netFlows, netDeposits, netWithdrawals);
    }

    function _computeTotalAssets(IOllaCore.AccountingState memory buckets)
        internal
        pure
        returns (uint256 totalAssets_)
    {
        totalAssets_ = buckets.bufferedAssets + buckets.stakedPrincipal + buckets.rewardsVaultBalance
            + buckets.claimableRewards - buckets.slashingDelta;
        return totalAssets_;
    }

    function _computeGrossRewards(uint256 oldTotalAssets, uint256 newTotalAssets, int256 netFlows)
        internal
        pure
        returns (uint256 grossRewards)
    {
        int256 changeInAssets = SafeCast.toInt256(newTotalAssets) - SafeCast.toInt256(oldTotalAssets);
        // Clamp signed delta; no timestamp-based control flow.
        // slither-disable-next-line timestamp
        // slither-disable-next-line timestamp
        int256 grossRewardsSigned = changeInAssets - netFlows;
        // slither-disable-next-line timestamp
        if (grossRewardsSigned > 0) {
            grossRewards = SafeCast.toUint256(grossRewardsSigned);
        }
        return grossRewards;
    }
}
