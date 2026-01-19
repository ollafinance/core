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

    /// @notice Contract related interfaces and addresses
    IERC20 private _asset;
    IStAztec private _stAztec;
    IStakingManager private _stakingManager;
    address private _governance;
    address private _withdrawalQueue;
    address private _rewardsVault;
    address private _safetyModule;

    /// @notice Accounting and reporting values
    IOllaCore.AccountingState private _accountingState;
    IOllaCore.FlowCounters private _flowCounters;
    IOllaCore.LatestReport private _latestReport;

    uint256 private _stakeMessageId;
    uint256 private _unstakeMessageId;

    mapping(address owner => PendingWithdrawal withdrawal) private _pendingWithdrawals;

    /// @notice Storage gap for upgradability
    // slither-disable-next-line unused-state
    uint256[36] private __gap;

    /// @notice Thrown when a pending withdrawal already exists.
    error OllaCorePendingWithdrawalExists(address owner);

    /// @notice Thrown when no pending withdrawal exists.
    error OllaCoreNoPendingWithdrawal(address owner);

    /// @notice Thrown when a zero address is provided.
    error OllaCoreZeroAddress();

    /// @notice Thrown when assets are unavailable for claiming.
    error OllaCoreInsufficientLiquidity(uint256 assets, uint256 available);

    /// @notice Thrown when a caller is not the share owner.
    error OllaCoreUnauthorized(address caller, address owner);

    /// @notice Thrown when a caller is not governance.
    error OllaCoreUnauthorizedGovernance(address caller);

    /// @notice Thrown when a bucket update amount is invalid.
    error OllaCoreInvalidAmount();

    /// @notice Thrown when a bucket lacks sufficient balance.
    error OllaCoreInsufficientBucketBalance(Bucket bucket, uint256 amount, uint256 available);

    /// @notice Thrown when buffered assets do not match the vault balance.
    error OllaCoreBufferedBalanceMismatch(uint256 expected, uint256 actual);

    constructor() {
        _disableInitializers();
    }

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
        if (
            address(asset_) == address(0) || address(stAztec_) == address(0) || address(stakingManager_) == address(0)
                || governance_ == address(0) || withdrawalQueue_ == address(0) || rewardsVault_ == address(0)
                || safetyModule_ == address(0)
        ) {
            revert OllaCoreZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        _asset = asset_;
        _stAztec = stAztec_;
        _stakingManager = stakingManager_;
        _governance = governance_;
        _withdrawalQueue = withdrawalQueue_;
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
    /// @param receiver The recipient of the stAztec shares.
    /// @return shares The shares minted to the receiver.
    function deposit(uint256 assets, address receiver)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (receiver == address(0)) {
            revert OllaCoreZeroAddress();
        }

        shares = _convertToSharesForDeposit(assets);
        _increaseBuffered(assets);
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _syncBufferedWithBalance();
        _increaseCumulativeDeposits(assets);

        _stAztec.mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    /// @notice Requests a redemption in shares.
    /// @param shares The number of shares to redeem.
    /// @param receiver The receiver of the assets.
    /// @param owner The owner of the shares.
    /// @return assets The assets expected from the redemption.
    function requestRedeem(uint256 shares, address receiver, address owner)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        assets = _convertToAssetsForRedeem(shares);
        _requestWithdrawal(shares, assets, receiver, owner);
        emit RequestRedeem(owner, receiver, assets, shares);
        return assets;
    }

    /// @notice Claims a pending withdrawal for an owner.
    /// @param owner The owner of the pending withdrawal.
    /// @return assets The assets transferred to the receiver.
    function claimPendingWithdraw(address owner) external override nonReentrant whenNotPaused returns (uint256 assets) {
        PendingWithdrawal memory pending = _pendingWithdrawals[owner];
        if (pending.shares == 0) {
            revert OllaCoreNoPendingWithdrawal(owner);
        }

        uint256 availableAssets = _accountingState.bufferedAssets;
        if (pending.assets > availableAssets) {
            revert OllaCoreInsufficientLiquidity(pending.assets, availableAssets);
        }

        assets = pending.assets;
        _clearPendingWithdrawal(owner);
        _decreaseBuffered(assets);
        _asset.safeTransfer(pending.receiver, assets);
        _syncBufferedWithBalance();
        emit Withdraw(msg.sender, pending.receiver, owner, assets, pending.shares);

        emit ClaimRedeem(owner, pending.receiver, assets, pending.shares);
        return assets;
    }

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

        emit ValidatorStateRead(updatedBuckets.rewardsDelta, updatedBuckets.slashingDelta, _latestReport.timestamp);
        emit AccountingUpdated(newTotalAssets, rate, grossRewards, netFlows, 0, 0, 0, _latestReport.timestamp);
    }

    // slither-disable-end pess-multiple-storage-read

    /// @notice Stubbed operator withdrawal finalization hook.
    /// @param available The available assets for withdrawals.
    /// @return used The assets used for finalization.
    function finalizeWithdrawals(uint256 available) external override onlyRole(OPERATOR_ROLE) returns (uint256 used) {
        emit WithdrawalFinalized(available, 0);
        return 0;
    }

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
        return _withdrawalQueue;
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

    /// @notice Returns the assets previewed for a redeem.
    /// @param shares The shares being redeemed.
    /// @return assets The assets that would be returned.
    function previewRedeem(uint256 shares) external view override returns (uint256 assets) {
        return _convertToAssetsForRedeem(shares);
    }

    /// @notice Returns the pending withdrawal for an owner.
    /// @param owner The owner to query.
    /// @return pending The pending withdrawal details.
    function pendingWithdrawal(address owner) external view override returns (PendingWithdrawal memory pending) {
        pending = _pendingWithdrawals[owner];
        return pending;
    }

    /// @notice Returns true if the interface is supported.
    /// @param interfaceId The interface identifier.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @notice Returns the current total assets held by the vault.
    /// @return The total assets held by the vault.
    function totalAssets() public view override returns (uint256) {
        IOllaCore.AccountingState storage buckets = _accountingState;
        return buckets.bufferedAssets + buckets.stakedPrincipal + buckets.rewardsVaultBalance + buckets.rewardsDelta
            - buckets.slashingDelta;
    }

    function _requestWithdrawal(uint256 shares, uint256 assets, address receiver, address owner) internal {
        if (receiver == address(0) || owner == address(0)) {
            revert OllaCoreZeroAddress();
        }

        if (_pendingWithdrawals[owner].shares != 0) {
            revert OllaCorePendingWithdrawalExists(owner);
        }

        if (msg.sender != owner) {
            revert OllaCoreUnauthorized(msg.sender, owner);
        }

        uint256 availableAssets = totalAssets();
        if (assets > availableAssets) {
            revert OllaCoreInsufficientLiquidity(assets, availableAssets);
        }

        _pendingWithdrawals[owner] = PendingWithdrawal({ shares: shares, assets: assets, receiver: receiver });

        _increaseCumulativeWithdrawals(assets);

        _stAztec.burn(owner, shares);
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
        _stakingManager.unStake(amount);
        _syncBufferedWithBalance();
    }

    function _clearPendingWithdrawal(address owner) internal {
        delete _pendingWithdrawals[owner];
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
        flows.latestReportDeposits = updatedCumulativeDeposits;
        flows.latestReportWithdrawals = updatedCumulativeWithdrawals;
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
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingState.bufferedAssets;
        uint256 newValue = oldValue + amount;
        _accountingState.bufferedAssets = newValue;
    }

    function _decreaseBuffered(uint256 amount) internal {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingState.bufferedAssets;
        if (amount > oldValue) {
            revert OllaCoreInsufficientBucketBalance(Bucket.Buffered, amount, oldValue);
        }
        uint256 newValue = oldValue - amount;
        _accountingState.bufferedAssets = newValue;
    }

    // slither-disable-next-line dead-code
    function _increaseStakedPrincipal(uint256 amount) internal onlyRole(OPERATOR_ROLE) {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingState.stakedPrincipal;
        uint256 newValue = oldValue + amount;
        _accountingState.stakedPrincipal = newValue;
    }

    // slither-disable-next-line dead-code
    function _decreaseStakedPrincipal(uint256 amount) internal onlyRole(OPERATOR_ROLE) {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingState.stakedPrincipal;
        if (amount > oldValue) {
            revert OllaCoreInsufficientBucketBalance(Bucket.StakedPrincipal, amount, oldValue);
        }
        uint256 newValue = oldValue - amount;
        _accountingState.stakedPrincipal = newValue;
    }

    // slither-disable-next-line dead-code
    function _increaseRewardsVaultBalance(uint256 amount) internal onlyRole(OPERATOR_ROLE) {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingState.rewardsVaultBalance;
        uint256 newValue = oldValue + amount;
        _accountingState.rewardsVaultBalance = newValue;
    }

    // slither-disable-next-line dead-code
    function _decreaseRewardsVaultBalance(uint256 amount) internal onlyRole(OPERATOR_ROLE) {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingState.rewardsVaultBalance;
        if (amount > oldValue) {
            revert OllaCoreInsufficientBucketBalance(Bucket.RewardsVault, amount, oldValue);
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
            revert OllaCoreBufferedBalanceMismatch(buffered, actual);
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

    function _convertToAssetsForRedeem(uint256 assets) internal view returns (uint256) {
        return _convertToAssets(assets, Math.Rounding.Ceil);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        IStAztec stAztecToken = _stAztec;
        uint256 supply = stAztecToken.totalSupply();
        if (supply == 0) {
            return shares;
        }
        return shares.mulDiv(totalAssets(), supply, rounding);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != _governance) {
            revert OllaCoreUnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert OllaCoreZeroAddress();
        }
    }

    function _computeNetFlows(IOllaCore.FlowCounters memory flows)
        internal
        pure
        returns (uint256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        netDeposits = flows.cumulativeDeposits > flows.latestReportDeposits
            ? flows.cumulativeDeposits - flows.latestReportDeposits
            : 0;
        netWithdrawals = flows.cumulativeWithdrawals > flows.latestReportWithdrawals
            ? flows.cumulativeWithdrawals - flows.latestReportWithdrawals
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
