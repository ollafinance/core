// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
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
contract OllaCore is Initializable, IOllaCore, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct AccountingBuckets {
        uint256 bufferedAssets;
        uint256 stakedPrincipal;
        uint256 rewardsVaultBalance;
        uint256 rewardsDelta;
        uint256 slashingDelta;
    }

    uint256 private constant _EXCHANGE_RATE_SCALE = 1e18;
    uint8 private constant _BUCKET_ID_BUFFERED = 0;
    uint8 private constant _BUCKET_ID_STAKED_PRINCIPAL = 1;
    uint8 private constant _BUCKET_ID_REWARDS_VAULT = 2;
    uint8 private constant _BUCKET_ID_REWARDS_DELTA = 3;
    uint8 private constant _BUCKET_ID_SLASHING_DELTA = 4;

    // slither-disable-start unused-state
    bytes32 private constant _BUCKET_UPDATE_REASON_DEPOSIT = "DEPOSIT";
    bytes32 private constant _BUCKET_UPDATE_REASON_CLAIM = "CLAIM";
    bytes32 private constant _BUCKET_UPDATE_REASON_STAKE = "STAKE";
    bytes32 private constant _BUCKET_UPDATE_REASON_UNSTAKE = "UNSTAKE";
    bytes32 private constant _BUCKET_UPDATE_REASON_SLASH = "SLASH";
    // slither-disable-end unused-state

    IERC20 private _asset;
    IStAztec private _stAztec;
    IStakingManager private _stakingManager;
    uint256 private _unusedReentrancyStatus;

    uint256 private _stakeMessageId;
    uint256 private _unstakeMessageId;

    mapping(address owner => PendingWithdrawal withdrawal) private _pendingWithdrawals;
    AccountingBuckets private _accountingBuckets;

    /// @notice Storage gap for upgradability
    // slither-disable-next-line unused-state
    uint256[47] private __gap;

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

    /// @notice Thrown when a bucket update amount is invalid.
    error OllaCoreInvalidAmount();

    /// @notice Thrown when a bucket lacks sufficient balance.
    error OllaCoreInsufficientBucketBalance(uint8 bucketId, uint256 amount, uint256 available);

    /// @notice Thrown when buffered assets do not match the vault balance.
    error OllaCoreBufferedBalanceMismatch(uint256 expected, uint256 actual);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the vault with asset and stAztec addresses.
    /// @param asset_ The underlying Aztec asset.
    /// @param stAztec_ The stAztec share token.
    /// @param stakingManager_ The staking manager for delegation messaging.
    function initialize(IERC20 asset_, IStAztec stAztec_, IStakingManager stakingManager_)
        external
        override
        initializer
    {
        if (address(asset_) == address(0) || address(stAztec_) == address(0) || address(stakingManager_) == address(0))
        {
            revert OllaCoreZeroAddress();
        }

        _asset = asset_;
        _stAztec = stAztec_;
        _stakingManager = stakingManager_;
        _unusedReentrancyStatus = 0;
    }

    /// @notice Deposits assets and mints stAztec shares.
    /// @param assets The amount of assets to deposit.
    /// @param receiver The recipient of the stAztec shares.
    /// @return shares The shares minted to the receiver.
    function deposit(uint256 assets, address receiver) external override nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) {
            revert OllaCoreZeroAddress();
        }

        shares = _convertToSharesForDeposit(assets);
        _increaseBuffered(assets, _BUCKET_UPDATE_REASON_DEPOSIT);
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _syncBufferedWithBalance();
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
    function claimPendingWithdraw(address owner) external override nonReentrant returns (uint256 assets) {
        PendingWithdrawal memory pending = _pendingWithdrawals[owner];
        if (pending.shares == 0) {
            revert OllaCoreNoPendingWithdrawal(owner);
        }

        uint256 availableAssets = _accountingBuckets.bufferedAssets;
        if (pending.assets > availableAssets) {
            revert OllaCoreInsufficientLiquidity(pending.assets, availableAssets);
        }

        assets = pending.assets;
        _clearPendingWithdrawal(owner);
        _decreaseBuffered(assets, _BUCKET_UPDATE_REASON_CLAIM);
        _asset.safeTransfer(pending.receiver, assets);
        _syncBufferedWithBalance();
        emit Withdraw(msg.sender, pending.receiver, owner, assets, pending.shares);

        emit ClaimRedeem(owner, pending.receiver, assets, pending.shares);
        return assets;
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

    /// @notice Returns the buffered assets held by the vault.
    /// @return The buffered asset amount.
    function bufferedAssets() external view override returns (uint256) {
        return _accountingBuckets.bufferedAssets;
    }

    /// @notice Returns the staked principal tracked by the vault.
    /// @return The staked principal amount.
    function stakedPrincipal() external view override returns (uint256) {
        return _accountingBuckets.stakedPrincipal;
    }

    /// @notice Returns the rewards vault balance tracked by the vault.
    /// @return The rewards vault balance amount.
    function rewardsVaultBalance() external view override returns (uint256) {
        return _accountingBuckets.rewardsVaultBalance;
    }

    /// @notice Returns the claimable rewards delta.
    /// @return The rewards delta amount.
    function rewardsDelta() external view override returns (uint256) {
        return _accountingBuckets.rewardsDelta;
    }

    /// @notice Returns the slashing delta applied to totals.
    /// @return The slashing delta amount.
    function slashingDelta() external view override returns (uint256) {
        return _accountingBuckets.slashingDelta;
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
        return shares.mulDiv(rate, _EXCHANGE_RATE_SCALE, Math.Rounding.Floor);
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

    /* solhint-disable comprehensive-interface */
    /// @notice Computes deposit shares using the protocol formula.
    /// @param assets The asset amount being deposited.
    /// @return shares The shares that would be minted.
    /// Formula: assets * totalSupply / totalAssets (floor), assets if supply == 0.
    function depositFormula(uint256 assets) external view returns (uint256 shares) {
        IStAztec stAztecToken = _stAztec;
        uint256 supply = stAztecToken.totalSupply();
        if (supply == 0) {
            return assets;
        }
        return assets.mulDiv(supply, totalAssets(), Math.Rounding.Floor);
    }

    /// @notice Returns the assets backing a user's shares.
    /// @param owner The share owner to value.
    /// @return assets The assets represented by the owner's shares.
    /// Formula: stAztec.balanceOf(owner) * exchangeRate / 1e18 (floor).
    function userValue(address owner) external view returns (uint256 assets) {
        uint256 shares = _stAztec.balanceOf(owner);
        if (shares == 0) {
            return 0;
        }
        uint256 supply = _stAztec.totalSupply();
        uint256 rate = supply == 0
            ? _EXCHANGE_RATE_SCALE
            : totalAssets().mulDiv(_EXCHANGE_RATE_SCALE, supply, Math.Rounding.Floor);
        return shares.mulDiv(rate, _EXCHANGE_RATE_SCALE, Math.Rounding.Floor);
    }

    /* solhint-enable comprehensive-interface */

    /// @notice Returns the pending withdrawal for an owner.
    /// @param owner The owner to query.
    /// @return The pending withdrawal details.
    function pendingWithdrawal(address owner) external view override returns (PendingWithdrawal memory) {
        return _pendingWithdrawals[owner];
    }

    /// @notice Returns the current total assets held by the vault.
    /// @return The total assets held by the vault.
    function totalAssets() public view override returns (uint256) {
        AccountingBuckets storage buckets = _accountingBuckets;
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

    function _increaseBuffered(uint256 amount, bytes32 reason) internal {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingBuckets.bufferedAssets;
        uint256 newValue = oldValue + amount;
        _accountingBuckets.bufferedAssets = newValue;
        emit BucketUpdated(_BUCKET_ID_BUFFERED, oldValue, newValue, reason);
    }

    function _decreaseBuffered(uint256 amount, bytes32 reason) internal {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingBuckets.bufferedAssets;
        if (amount > oldValue) {
            revert OllaCoreInsufficientBucketBalance(_BUCKET_ID_BUFFERED, amount, oldValue);
        }
        uint256 newValue = oldValue - amount;
        _accountingBuckets.bufferedAssets = newValue;
        emit BucketUpdated(_BUCKET_ID_BUFFERED, oldValue, newValue, reason);
    }

    // slither-disable-next-line dead-code
    function _increaseStakedPrincipal(uint256 amount, bytes32 reason) internal {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingBuckets.stakedPrincipal;
        uint256 newValue = oldValue + amount;
        _accountingBuckets.stakedPrincipal = newValue;
        emit BucketUpdated(_BUCKET_ID_STAKED_PRINCIPAL, oldValue, newValue, reason);
    }

    // slither-disable-next-line dead-code
    function _decreaseStakedPrincipal(uint256 amount, bytes32 reason) internal {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingBuckets.stakedPrincipal;
        if (amount > oldValue) {
            revert OllaCoreInsufficientBucketBalance(_BUCKET_ID_STAKED_PRINCIPAL, amount, oldValue);
        }
        uint256 newValue = oldValue - amount;
        _accountingBuckets.stakedPrincipal = newValue;
        emit BucketUpdated(_BUCKET_ID_STAKED_PRINCIPAL, oldValue, newValue, reason);
    }

    // slither-disable-next-line dead-code
    function _increaseRewardsVaultBalance(uint256 amount, bytes32 reason) internal {
        if (amount == 0) {
            revert OllaCoreInvalidAmount();
        }
        uint256 oldValue = _accountingBuckets.rewardsVaultBalance;
        uint256 newValue = oldValue + amount;
        _accountingBuckets.rewardsVaultBalance = newValue;
        emit BucketUpdated(_BUCKET_ID_REWARDS_VAULT, oldValue, newValue, reason);
    }

    // slither-disable-next-line dead-code
    function _setRewardsDelta(uint256 newValue, bytes32 reason) internal {
        uint256 oldValue = _accountingBuckets.rewardsDelta;
        _accountingBuckets.rewardsDelta = newValue;
        emit BucketUpdated(_BUCKET_ID_REWARDS_DELTA, oldValue, newValue, reason);
    }

    // slither-disable-next-line dead-code
    function _setSlashingDelta(uint256 newValue, bytes32 reason) internal {
        uint256 oldValue = _accountingBuckets.slashingDelta;
        _accountingBuckets.slashingDelta = newValue;
        emit BucketUpdated(_BUCKET_ID_SLASHING_DELTA, oldValue, newValue, reason);
    }

    function _syncBufferedWithBalance() internal view {
        uint256 buffered = _accountingBuckets.bufferedAssets;
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
}
