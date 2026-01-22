// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IOllaCore } from "src/interfaces/IOllaCore.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { IStAztec } from "src/interfaces/IStAztec.sol";
import { IWithdrawalQueue } from "src/interfaces/IWithdrawalQueue.sol";

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
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Role for operator accounting actions.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// @notice Role for core module callbacks.
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract related interfaces and addresses
    IERC20 private _asset;
    IStAztec private _stAztec;
    IStakingManager private _stakingManager;
    address private _governance;
    IWithdrawalQueue private _withdrawalQueue;
    address private _rewardsVault;
    address private _safetyModule;

    /// @notice Accounting and reporting values
    IOllaCore.AccountingState private _accountingState;
    IOllaCore.FlowCounters private _flowCounters;
    IOllaCore.LatestReport private _latestReport;

    uint256 private _stakeMessageId;
    uint256 private _unstakeMessageId;

    mapping(address owner => uint256 requestId) private _activeRequestIds;
    mapping(uint256 requestId => address owner) private _requestOwners;

    /// @notice Storage gap for upgradability
    // slither-disable-next-line unused-state
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a caller is not governance.
    error OllaCore__UnauthorizedGovernance(address caller);

    /// @notice Thrown when a bucket update amount is invalid.
    error OllaCore__InvalidAmount();

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

    /// @notice Initializes the vault with asset and module addresses.
    /// @param asset_ The underlying Aztec asset.
    /// @param stAztec_ The stAztec share token.
    /// @param stakingManager_ The staking manager for delegation messaging.
    /// @param governance_ The governance address authorized to upgrade.
    /// @param withdrawalQueue_ The withdrawal queue module address.
    /// @param rewardsVault_ The rewards vault module address.
    /// @param safetyModule_ The safety module address.
    function initialize(
        IERC20 asset_,
        IStAztec stAztec_,
        IStakingManager stakingManager_,
        address governance_,
        address withdrawalQueue_,
        address rewardsVault_,
        address safetyModule_
    ) external override initializer {
        if (address(asset_) == address(0)) {
            revert OllaCore__ZeroAddress("asset_");
        }
        if (address(stAztec_) == address(0)) {
            revert OllaCore__ZeroAddress("stAztec_");
        }
        if (address(stakingManager_) == address(0)) {
            revert OllaCore__ZeroAddress("stakingManager_");
        }
        if (governance_ == address(0)) {
            revert OllaCore__ZeroAddress("governance_");
        }
        if (withdrawalQueue_ == address(0)) {
            revert OllaCore__ZeroAddress("withdrawalQueue_");
        }
        if (rewardsVault_ == address(0)) {
            revert OllaCore__ZeroAddress("rewardsVault_");
        }
        if (safetyModule_ == address(0)) {
            revert OllaCore__ZeroAddress("safetyModule_");
        }

        __AccessControl_init();
        __Pausable_init();

        _asset = asset_;
        _stAztec = stAztec_;
        _stakingManager = stakingManager_;
        _governance = governance_;
        _withdrawalQueue = IWithdrawalQueue(withdrawalQueue_);
        _rewardsVault = rewardsVault_;
        _safetyModule = safetyModule_;
        _latestReport.exchangeRate = _EXCHANGE_RATE_SCALE;
        _latestReport.timestamp = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, governance_);
        _grantRole(GUARDIAN_ROLE, governance_);
        _grantRole(CORE_ROLE, address(this));
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
        if (recipient == address(0)) {
            revert OllaCore__ZeroAddress("recipient");
        }

        shares = _convertToSharesForDeposit(assets);
        _increaseBuffered(assets);
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _syncBufferedWithBalance();
        _increaseCumulativeDeposits(assets);

        _stAztec.mint(recipient, shares);
        emit Deposit(msg.sender, recipient, assets, shares);
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
        address owner = msg.sender;
        if (recipient == address(0)) {
            revert OllaCore__ZeroAddress("recipient");
        }

        if (_activeRequestIds[owner] != 0) {
            revert OllaCore__PendingWithdrawalExists(owner);
        }

        uint256 rate = _exchangeRate();
        uint256 assetsExpected = shares.mulDiv(rate, _EXCHANGE_RATE_SCALE, Math.Rounding.Floor);
        uint256 expectedRequestId = _withdrawalQueue.nextRequestId();

        _activeRequestIds[owner] = expectedRequestId;
        _requestOwners[expectedRequestId] = owner;
        _increaseCumulativeWithdrawals(assetsExpected);
        _stAztec.burn(owner, shares);

        requestId = _withdrawalQueue.requestWithdrawal(recipient, shares, assetsExpected, rate);
        if (requestId != expectedRequestId) {
            revert OllaCore__UnexpectedRequestId(expectedRequestId, requestId);
        }

        emit WithdrawalRequested(requestId, recipient, shares, assetsExpected, rate);
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

    /// @notice Stubbed operator rebalance hook.
    function rebalance() external override onlyRole(OPERATOR_ROLE) {
        emit Rebalanced(0, 0, 0, 0);
    }

    // slither-disable-start pess-multiple-storage-read
    /// @notice Updates accounting snapshots and publishes the latest exchange rate data.
    function updateAccounting() external override onlyRole(OPERATOR_ROLE) {
        IOllaCore.FlowCounters memory flowsSnapshot = _flowCounters;
        (uint256 netFlows,,) = _computeNetFlows(flowsSnapshot);

        uint256 oldTotalAssets = _latestReport.totalAssets;

        IOllaCore.AccountingState storage buckets = _accountingState;
        _applyAccountingUpdates(
            buckets.stakedPrincipal, buckets.rewardsVaultBalance, buckets.rewardsDelta, buckets.slashingDelta
        );

        IOllaCore.AccountingState memory updatedBuckets = _accountingState;
        uint256 newTotalAssets = _computeTotalAssets(updatedBuckets);
        uint256 grossRewards = _computeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        uint256 rate = _exchangeRate();

        _updateReportingSnapshots(
            newTotalAssets,
            rate,
            grossRewards,
            netFlows,
            flowsSnapshot.cumulativeDeposits,
            flowsSnapshot.cumulativeWithdrawals
        );

        emit AttestersStateRead(updatedBuckets.rewardsDelta, updatedBuckets.slashingDelta, _latestReport.timestamp);
        emit AccountingUpdated(newTotalAssets, rate, grossRewards, netFlows, 0, 0, 0, _latestReport.timestamp);
    }

    // slither-disable-end pess-multiple-storage-read

    /// @notice Operator-triggered withdrawal finalization hook.
    /// @param available The available assets for withdrawals.
    /// @return used The assets used for finalization.
    function finalizeWithdrawals(uint256 available)
        external
        override
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 used)
    {
        _syncBufferedWithBalance();

        uint256 bufferedAssets = _accountingState.bufferedAssets;
        if (available > bufferedAssets) {
            revert OllaCore__InsufficientBucketBalance(Bucket.Buffered, available, bufferedAssets);
        }

        used = _withdrawalQueue.previewFinalizeWithdrawals(available);
        _accountingState.bufferedAssets = bufferedAssets - used;

        uint256 finalized = _withdrawalQueue.finalizeWithdrawals(available);
        if (finalized != used) {
            revert OllaCore__FinalizeAmountMismatch(used, finalized);
        }

        emit WithdrawalFinalized(available, used);
        return used;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the underlying asset address.
    /// @return The underlying asset address.
    function asset() external view override returns (address) {
        return address(_asset);
    }

    /// @notice Returns the stAztec share token address.
    /// @return The stAztec share token address.
    function stAztec() external view override returns (address) {
        return address(_stAztec);
    }

    /// @notice Returns the staking manager address.
    /// @return The staking manager address.
    function stakingManager() external view override returns (address) {
        return address(_stakingManager);
    }

    /// @notice Returns the governance address.
    /// @return The governance address.
    function governance() external view override returns (address) {
        return _governance;
    }

    /// @notice Returns the withdrawal queue module address.
    /// @return The withdrawal queue address.
    function withdrawalQueue() external view override returns (address) {
        return address(_withdrawalQueue);
    }

    /// @notice Returns the rewards vault module address.
    /// @return The rewards vault address.
    function rewardsVault() external view override returns (address) {
        return _rewardsVault;
    }

    /// @notice Returns the safety module address.
    /// @return The safety module address.
    function safetyModule() external view override returns (address) {
        return _safetyModule;
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
        uint256 rate = _exchangeRate();
        assets = shares.mulDiv(rate, _EXCHANGE_RATE_SCALE, Math.Rounding.Floor);
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
        return buckets.bufferedAssets + buckets.stakedPrincipal + buckets.rewardsVaultBalance + buckets.rewardsDelta
            - buckets.slashingDelta;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _claimWithdrawal(uint256 requestId) internal returns (uint256 assets) {
        IWithdrawalQueue queue = _withdrawalQueue;
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

        _asset.safeTransfer(receiver, assets);
        emit WithdrawalClaimed(requestId, receiver, assets);
        return assets;
    }

    // slither-disable-next-line dead-code
    function _stake(uint256 amount) internal {
        uint256 messageId = ++_stakeMessageId;
        emit StakeRequested(messageId, amount);
        _stakingManager.stake(amount);
        _syncBufferedWithBalance();
    }

    // slither-disable-next-line dead-code
    function _unstake(uint256 amount) internal {
        uint256 messageId = ++_unstakeMessageId;
        emit UnstakeRequested(messageId, amount);
        _stakingManager.unstake(amount);
        _syncBufferedWithBalance();
    }

    function _increaseCumulativeDeposits(uint256 amount) internal {
        _flowCounters.cumulativeDeposits += amount;
    }

    function _increaseCumulativeWithdrawals(uint256 amount) internal {
        _flowCounters.cumulativeWithdrawals += amount;
    }

    // slither-disable-next-line pess-multiple-storage-read
    function _updateReportingSnapshots(
        uint256 total,
        uint256 rate,
        uint256 grossRewards,
        uint256 netFlows,
        uint256 updatedCumulativeDeposits,
        uint256 updatedCumulativeWithdrawals
    ) internal {
        IOllaCore.LatestReport storage report = _latestReport;
        report.totalAssets = total;
        report.exchangeRate = rate;
        report.grossRewards = grossRewards;
        report.netFlows = netFlows;
        report.timestamp = block.timestamp;

        IOllaCore.FlowCounters storage flows = _flowCounters;
        flows.latestReportCumulativeDeposits = updatedCumulativeDeposits;
        flows.latestReportCumulativeWithdrawals = updatedCumulativeWithdrawals;
    }

    function _applyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsVaultBalance,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) internal {
        uint256 currentStaked = _accountingState.stakedPrincipal;
        if (newStakedPrincipal > currentStaked) {
            _increaseStakedPrincipal(newStakedPrincipal - currentStaked);
        } else if (newStakedPrincipal < currentStaked) {
            _decreaseStakedPrincipal(currentStaked - newStakedPrincipal);
        }

        uint256 currentRewardsVault = _accountingState.rewardsVaultBalance;
        if (newRewardsVaultBalance > currentRewardsVault) {
            _increaseRewardsVaultBalance(newRewardsVaultBalance - currentRewardsVault);
        } else if (newRewardsVaultBalance < currentRewardsVault) {
            _decreaseRewardsVaultBalance(currentRewardsVault - newRewardsVaultBalance);
        }

        _setRewardsDelta(newRewardsDelta);
        _setSlashingDelta(newSlashingDelta);
    }

    function _increaseBuffered(uint256 amount) internal {
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        uint256 oldValue = _accountingState.bufferedAssets;
        uint256 newValue = oldValue + amount;
        _accountingState.bufferedAssets = newValue;
    }

    // slither-disable-next-line dead-code
    function _increaseStakedPrincipal(uint256 amount) internal onlyRole(OPERATOR_ROLE) {
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        uint256 oldValue = _accountingState.stakedPrincipal;
        uint256 newValue = oldValue + amount;
        _accountingState.stakedPrincipal = newValue;
    }

    // slither-disable-next-line dead-code
    function _decreaseStakedPrincipal(uint256 amount) internal onlyRole(OPERATOR_ROLE) {
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        uint256 oldValue = _accountingState.stakedPrincipal;
        if (amount > oldValue) {
            revert OllaCore__InsufficientBucketBalance(Bucket.StakedPrincipal, amount, oldValue);
        }
        uint256 newValue = oldValue - amount;
        _accountingState.stakedPrincipal = newValue;
    }

    // slither-disable-next-line dead-code
    function _increaseRewardsVaultBalance(uint256 amount) internal onlyRole(OPERATOR_ROLE) {
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        uint256 oldValue = _accountingState.rewardsVaultBalance;
        uint256 newValue = oldValue + amount;
        _accountingState.rewardsVaultBalance = newValue;
    }

    // slither-disable-next-line dead-code
    function _decreaseRewardsVaultBalance(uint256 amount) internal onlyRole(OPERATOR_ROLE) {
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        uint256 oldValue = _accountingState.rewardsVaultBalance;
        if (amount > oldValue) {
            revert OllaCore__InsufficientBucketBalance(Bucket.RewardsVault, amount, oldValue);
        }
        uint256 newValue = oldValue - amount;
        _accountingState.rewardsVaultBalance = newValue;
    }

    // slither-disable-next-line dead-code
    function _setRewardsDelta(uint256 newValue) internal onlyRole(OPERATOR_ROLE) {
        _accountingState.rewardsDelta = newValue;
    }

    // slither-disable-next-line dead-code
    function _setSlashingDelta(uint256 newValue) internal onlyRole(OPERATOR_ROLE) {
        _accountingState.slashingDelta = newValue;
    }

    function _syncBufferedWithBalance() internal view {
        uint256 buffered = _accountingState.bufferedAssets;
        uint256 actual = _asset.balanceOf(address(this));
        if (buffered != actual) {
            revert OllaCore__BufferedBalanceMismatch(buffered, actual);
        }
    }

    function _exchangeRate() internal view returns (uint256) {
        IStAztec stAztecToken = _stAztec;
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
        IStAztec stAztecToken = _stAztec;
        uint256 supply = stAztecToken.totalSupply();
        if (supply == 0) {
            return assets;
        }
        return assets.mulDiv(supply, totalAssets(), rounding);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != _governance) {
            revert OllaCore__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert OllaCore__ZeroAddress("newImplementation");
        }
    }

    function _computeNetFlows(IOllaCore.FlowCounters memory flows)
        internal
        pure
        returns (uint256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        netDeposits = flows.cumulativeDeposits > flows.latestReportCumulativeDeposits
            ? flows.cumulativeDeposits - flows.latestReportCumulativeDeposits
            : 0;
        netWithdrawals = flows.cumulativeWithdrawals > flows.latestReportCumulativeWithdrawals
            ? flows.cumulativeWithdrawals - flows.latestReportCumulativeWithdrawals
            : 0;
        netFlows = netDeposits > netWithdrawals ? netDeposits - netWithdrawals : 0;
        return (netFlows, netDeposits, netWithdrawals);
    }

    function _computeTotalAssets(IOllaCore.AccountingState memory buckets)
        internal
        pure
        returns (uint256 totalAssets_)
    {
        totalAssets_ = buckets.bufferedAssets + buckets.stakedPrincipal + buckets.rewardsVaultBalance
            + buckets.rewardsDelta - buckets.slashingDelta;
        return totalAssets_;
    }

    function _computeGrossRewards(uint256 oldTotalAssets, uint256 newTotalAssets, uint256 netFlows)
        internal
        pure
        returns (uint256 grossRewards)
    {
        uint256 changeInAssets = newTotalAssets > oldTotalAssets ? newTotalAssets - oldTotalAssets : 0;
        grossRewards = changeInAssets > netFlows ? changeInAssets - netFlows : 0;
        return grossRewards;
    }
}
