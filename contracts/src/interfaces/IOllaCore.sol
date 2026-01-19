// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { IStAztec } from "src/interfaces/IStAztec.sol";

/// @title IOllaCore
/// @notice Interface for the OllaCore vault with async withdrawals.
/// @author Olla Core contributors
interface IOllaCore {
    struct PendingWithdrawal {
        uint256 shares;
        uint256 assets;
        address receiver;
    }

    // solhint-disable gas-indexed-events
    /// @notice Emitted when a deposit is completed.
    /// @param caller The address that initiated the deposit.
    /// @param receiver The address receiving the shares.
    /// @param assets The assets deposited.
    /// @param shares The shares minted.
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when a withdrawal is completed.
    /// @param caller The address that initiated the withdrawal.
    /// @param receiver The address receiving the assets.
    /// @param owner The share owner.
    /// @param assets The assets withdrawn.
    /// @param shares The shares burned.
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Emitted when a withdrawal request is created.
    /// @param owner The share owner that requested the withdrawal.
    /// @param receiver The address receiving the assets.
    /// @param assets The assets requested.
    /// @param shares The shares burned.
    event RequestWithdraw(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when a redeem request is created.
    /// @param owner The share owner that requested the redemption.
    /// @param receiver The address receiving the assets.
    /// @param assets The assets requested.
    /// @param shares The shares burned.
    event RequestRedeem(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when a redeem request is claimed.
    /// @param owner The share owner that requested the redemption.
    /// @param receiver The address receiving the assets.
    /// @param assets The assets paid out.
    /// @param shares The shares burned.
    event ClaimRedeem(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when a stake message is sent to the staking manager.
    /// @param messageId Monotonic message id.
    /// @param amount The amount requested to stake.
    event StakeRequested(uint256 indexed messageId, uint256 amount);

    /// @notice Emitted when an unstake message is sent to the staking manager.
    /// @param messageId Monotonic message id.
    /// @param amount The amount requested to unstake.
    event UnstakeRequested(uint256 indexed messageId, uint256 amount);

    /// @notice Emitted when a bucket value changes.
    /// @param bucketId The bucket identifier.
    /// @param oldValue The previous bucket value.
    /// @param newValue The updated bucket value.
    /// @param reason The reason code for the update.
    event BucketUpdated(uint8 bucketId, uint256 oldValue, uint256 newValue, bytes32 reason);

    /// @notice Emitted when accounting is updated.
    /// @param totalAssets Total assets snapshot.
    /// @param exchangeRate Stored exchange rate snapshot.
    /// @param cumulativeDeposits Lifetime deposits.
    /// @param cumulativeWithdrawals Lifetime withdrawals.
    event AccountingUpdated(
        uint256 totalAssets, uint256 exchangeRate, uint256 cumulativeDeposits, uint256 cumulativeWithdrawals
    );

    /// @notice Emitted when validator state is read.
    /// @param rewardsDelta Rewards delta snapshot.
    /// @param slashingDelta Slashing delta snapshot.
    /// @param timestamp Timestamp of the read.
    event ValidatorStateRead(uint256 rewardsDelta, uint256 slashingDelta, uint256 timestamp);

    /// @notice Emitted when a rebalance occurs.
    /// @param bufferedAssets Buffered asset snapshot.
    /// @param stakedPrincipal Staked principal snapshot.
    /// @param rewardsVaultBalance Rewards vault balance snapshot.
    /// @param rewardsDelta Rewards delta snapshot.
    event Rebalanced(
        uint256 bufferedAssets, uint256 stakedPrincipal, uint256 rewardsVaultBalance, uint256 rewardsDelta
    );

    /// @notice Emitted when withdrawals are finalized.
    /// @param available Available assets.
    /// @param used Used assets.
    event WithdrawalFinalized(uint256 available, uint256 used);

    /// @notice Emitted when a withdrawal is claimed via queue.
    /// @param requestId Withdrawal request id.
    /// @param receiver Receiver address.
    /// @param assets Assets claimed.
    event WithdrawalClaimed(uint256 requestId, address receiver, uint256 assets);

    /// @notice Emitted when rewards are harvested.
    /// @param harvested Harvested reward amount.
    event RewardsHarvested(uint256 harvested);

    /// @notice Emitted when the core is paused.
    event Paused();

    /// @notice Emitted when the core is unpaused.
    event Unpaused();
    // solhint-enable gas-indexed-events

    // solhint-disable max-line-length
    /// @notice Initializes the vault with the Aztec asset address.
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
    ) external;
    // solhint-enable max-line-length

    /// @notice Deposits assets and mints stAztec shares.
    /// @param assets The amount of assets to deposit.
    /// @param receiver The recipient of the stAztec shares.
    /// @return shares The shares minted to the receiver.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Requests a redemption in shares.
    /// @param shares The number of shares to redeem.
    /// @param receiver The receiver of the assets.
    /// @param owner The owner of the shares.
    /// @return assets The assets expected from the redemption.
    function requestRedeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Claims a pending withdrawal for an owner.
    /// @param owner The owner of the pending withdrawal.
    /// @return assets The assets transferred to the receiver.
    function claimPendingWithdraw(address owner) external returns (uint256 assets);

    /// @notice Pauses deposits and withdrawals.
    function pause() external;

    /// @notice Unpauses deposits and withdrawals.
    function unpause() external;

    /// @notice Operator-triggered rebalance hook.
    function rebalance() external;

    /// @notice Operator-triggered accounting update hook.
    function updateAccounting() external;

    /// @notice Operator-triggered withdrawal finalization hook.
    /// @param available The available assets for withdrawals.
    /// @return used The assets used for finalization.
    function finalizeWithdrawals(uint256 available) external returns (uint256 used);

    /// @notice Returns the underlying asset address.
    /// @return The underlying asset address.
    function asset() external view returns (address);

    /// @notice Returns the stAztec share token address.
    /// @return The stAztec share token address.
    function stAztec() external view returns (address);

    /// @notice Returns the staking manager address.
    /// @return The staking manager address.
    function stakingManager() external view returns (address);

    /// @notice Returns the governance address.
    /// @return The governance address.
    function governance() external view returns (address);

    /// @notice Returns the withdrawal queue module address.
    /// @return The withdrawal queue address.
    function withdrawalQueue() external view returns (address);

    /// @notice Returns the rewards vault module address.
    /// @return The rewards vault address.
    function rewardsVault() external view returns (address);

    /// @notice Returns the safety module address.
    /// @return The safety module address.
    function safetyModule() external view returns (address);

    /// @notice Returns the stored exchange rate snapshot.
    /// @return The stored exchange rate.
    function storedExchangeRate() external view returns (uint256);

    /// @notice Returns the last total assets snapshot.
    /// @return The last total assets value.
    function lastTotalAssets() external view returns (uint256);

    /// @notice Returns cumulative deposits.
    /// @return The cumulative deposits value.
    function cumulativeDeposits() external view returns (uint256);

    /// @notice Returns cumulative withdrawals.
    /// @return The cumulative withdrawals value.
    function cumulativeWithdrawals() external view returns (uint256);

    /// @notice Returns last report deposits snapshot.
    /// @return The last report deposits value.
    function lastReportDeposits() external view returns (uint256);

    /// @notice Returns last report withdrawals snapshot.
    /// @return The last report withdrawals value.
    function lastReportWithdrawals() external view returns (uint256);

    /// @notice Returns the buffered assets held by the vault.
    /// @return The buffered asset amount.
    function bufferedAssets() external view returns (uint256);

    /// @notice Returns the staked principal tracked by the vault.
    /// @return The staked principal amount.
    function stakedPrincipal() external view returns (uint256);

    /// @notice Returns the rewards vault balance tracked by the vault.
    /// @return The rewards vault balance amount.
    function rewardsVaultBalance() external view returns (uint256);

    /// @notice Returns the claimable rewards delta.
    /// @return The rewards delta amount.
    function rewardsDelta() external view returns (uint256);

    /// @notice Returns the slashing delta applied to totals.
    /// @return The slashing delta amount.
    function slashingDelta() external view returns (uint256);

    /// @notice Returns the current total assets held by the vault.
    /// @return The total assets held by the vault.
    function totalAssets() external view returns (uint256);

    /// @notice Returns the current exchange rate in 18-decimal fixed-point units.
    /// @return The exchange rate scaled by 1e18.
    function exchangeRate() external view returns (uint256);

    /// @notice Computes the shares for an asset amount.
    /// @param assets The asset amount being converted.
    /// @return shares The shares that would be minted.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Computes the assets for a share amount.
    /// @param shares The share amount being converted.
    /// @return assets The assets that would be returned.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the shares previewed for a deposit.
    /// @param assets The asset amount being deposited.
    /// @return shares The shares that would be minted.
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Returns the assets previewed for a redeem.
    /// @param shares The shares being redeemed.
    /// @return assets The assets that would be returned.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the pending withdrawal for an owner.
    /// @param owner The owner to query.
    /// @return The pending withdrawal details.
    function pendingWithdrawal(address owner) external view returns (PendingWithdrawal memory);
}
