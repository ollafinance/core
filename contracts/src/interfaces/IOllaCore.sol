// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { IStAztec } from "src/interfaces/IStAztec.sol";

/// @title IOllaCore
/// @notice Interface for the OllaCore vault with async withdrawals.
/// @author Olla Core contributors
interface IOllaCore {
    struct AccountingState {
        uint256 bufferedAssets;
        uint256 stakedPrincipal;
        uint256 rewardsVaultBalance;
        uint256 rewardsDelta;
        uint256 slashingDelta;
    }

    struct FlowCounters {
        uint256 cumulativeDeposits;
        uint256 cumulativeWithdrawals;
        uint256 latestReportCumulativeDeposits;
        uint256 latestReportCumulativeWithdrawals;
    }

    struct LatestReport {
        uint256 totalAssets;
        uint256 exchangeRate;
        uint256 grossRewards;
        uint256 netFlows;
        uint256 timestamp;
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
    /// @param requestId The withdrawal request id.
    /// @param receiver The address receiving the assets.
    /// @param shares The shares burned.
    /// @param assetsExpected The assets expected at request time.
    /// @param exchangeRate The exchange rate locked at request time.
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed receiver,
        uint256 shares,
        uint256 assetsExpected,
        uint256 exchangeRate
    );

    /// @notice Emitted when a stake message is sent to the staking manager.
    /// @param messageId Monotonic message id.
    /// @param amount The amount requested to stake.
    event StakeRequested(uint256 indexed messageId, uint256 amount);

    /// @notice Emitted when an unstake message is sent to the staking manager.
    /// @param messageId Monotonic message id.
    /// @param amount The amount requested to unstake.
    event UnstakeRequested(uint256 indexed messageId, uint256 amount);

    /// @notice Emitted when accounting is updated.
    /// @param totalAssets Total assets snapshot.
    /// @param exchangeRate Stored exchange rate snapshot.
    /// @param grossRewards Gross rewards since last report.
    /// @param netFlows Net deposits minus withdrawals since last report.
    /// @param protocolFeeAssets Protocol fee amount in assets.
    /// @param treasuryShares Treasury fee shares minted.
    /// @param providerShares Provider fee shares minted.
    /// @param timestamp Timestamp of the report.
    event AccountingUpdated(
        uint256 totalAssets,
        uint256 exchangeRate,
        uint256 grossRewards,
        uint256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares,
        uint256 timestamp
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
    /// @return requestId The withdrawal request id.
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 requestId);

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

    /// @notice Returns the latest accounting report snapshot.
    /// @return The latest report struct.
    function latestReport() external view returns (LatestReport memory);

    /// @notice Returns the flow counter snapshots.
    /// @return The flow counters struct.
    function flowCounters() external view returns (FlowCounters memory);

    /// @notice Returns the accounting buckets snapshot.
    /// @return The accounting state struct.
    function accountingState() external view returns (AccountingState memory);

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
}
