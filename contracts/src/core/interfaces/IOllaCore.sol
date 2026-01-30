// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { IStAztec } from "src/core/interfaces/IStAztec.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

/// @title IOllaCore
/// @notice Interface for the OllaCore vault with async withdrawals.
/// @author Olla Core contributors
interface IOllaCore {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct AccountingState {
        uint256 bufferedAssets;
        uint256 stakedPrincipal;
        uint256 rewardsVaultBalance;
        uint256 claimableRewards;
        uint256 rewardsDelta;
        uint256 slashingDelta;
        uint256 cumulativeRewards;
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
        int256 netFlows;
        uint256 rewardsSnapshot;
        uint256 timestamp;
    }

    struct Modules {
        IERC20 asset;
        IStAztec stAztec;
        IStakingManager stakingManager;
        address governance;
        IWithdrawalQueue withdrawalQueue;
        IRewardsVault rewardsVault;
        address safetyModule;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // solhint-disable gas-indexed-events
    /// @notice Emitted when a deposit is completed.
    /// @param caller The address that initiated the deposit.
    /// @param recipient The address receiving the shares.
    /// @param assets The assets deposited.
    /// @param shares The shares minted.
    event Deposit(address indexed caller, address indexed recipient, uint256 assets, uint256 shares);

    /// @notice Emitted when a withdrawal is completed.
    /// @param caller The address that initiated the withdrawal.
    /// @param recipient The address receiving the assets.
    /// @param owner The share owner.
    /// @param assets The assets withdrawn.
    /// @param shares The shares burned.
    event Withdraw(
        address indexed caller, address indexed recipient, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Emitted when a withdrawal request is created.
    /// @param requestId The withdrawal request id.
    /// @param recipient The address receiving the assets.
    /// @param shares The shares burned.
    /// @param assetsExpected The assets expected at request time.
    /// @param exchangeRate The exchange rate locked at request time.
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed recipient,
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

    /// @notice Emitted when the protocol fee is updated.
    /// @param oldFeeBP The old fee in basis points.
    /// @param newFeeBP The new fee in basis points.
    event ProtocolFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);

    /// @notice Emitted when the treasury fee split is updated.
    /// @param oldSplitBP The old split in basis points.
    /// @param newSplitBP The new split in basis points.
    event TreasuryFeeSplitUpdated(uint256 oldSplitBP, uint256 newSplitBP);

    /// @notice Emitted when the governance address is updated.
    /// @param oldGovernance The old governance address.
    /// @param newGovernance The new governance address.
    event GovernanceUpdated(address oldGovernance, address newGovernance);

    /// @notice Emitted when the rewards vault address is updated.
    /// @param oldRewardsVault The old rewards vault address.
    /// @param newRewardsVault The new rewards vault address.
    event RewardsVaultUpdated(address oldRewardsVault, address newRewardsVault);

    /// @notice Emitted when protocol fees are paid.
    /// @param protocolFeeAssets Protocol fee amount in assets.
    /// @param treasuryShares Treasury fee shares minted.
    /// @param providerShares Provider fee shares minted.
    event OllaProtocolFeesPaid(uint256 protocolFeeAssets, uint256 treasuryShares, uint256 providerShares);

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
        int256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares,
        uint256 timestamp
    );

    /// @notice Emitted when attester state is read.
    /// @param rewardsDelta Rewards delta snapshot.
    /// @param slashingDelta Slashing delta snapshot.
    /// @param timestamp Timestamp of the read.
    event AttestersStateRead(uint256 rewardsDelta, uint256 slashingDelta, uint256 timestamp);

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
    /// @param recipient Recipient address.
    /// @param assets Assets claimed.
    event WithdrawalClaimed(uint256 requestId, address recipient, uint256 assets);

    /// @notice Emitted when rewards delta is updated.
    /// @param delta The rewards delta amount.
    event RewardsDelta(uint256 delta);

    /// @notice Emitted when the core is paused.
    event Paused();

    /// @notice Emitted when the core is unpaused.
    event Unpaused();
    // solhint-enable gas-indexed-events

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a pending withdrawal already exists.
    error OllaCore__PendingWithdrawalExists(address owner);

    /// @notice Thrown when a zero address is provided.
    error OllaCore__ZeroAddress(string param);

    /// @notice Thrown when queue request ids are inconsistent.
    error OllaCore__UnexpectedRequestId(uint256 expected, uint256 actual);

    /// @notice Thrown when previewed and finalized amounts mismatch.
    error OllaCore__FinalizeAmountMismatch(uint256 previewed, uint256 finalized);

    /// @notice Thrown when a deposit exceeds the configured cap.
    error OllaCore__DepositCapExceeded(uint256 assets, uint256 totalAssets);

    /// @notice Thrown when deposits are blocked by the safety module pause.
    error OllaCore__SafetyModulePaused();

    /// @notice Thrown when a slashing delta is invalid.
    error OllaCore__InvalidSlashingDelta(uint256 previous, uint256 current);

    /// @notice Thrown when a fee basis points value exceeds maximum.
    error OllaCore__InvalidFeeBP(uint256 feeBP);

    /// @notice Thrown when a split basis points value exceeds maximum.
    error OllaCore__InvalidSplitBP(uint256 splitBP);

    /// @notice Thrown when no active withdrawal request exists.
    error OllaCore__NoActiveWithdrawal(address owner);

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the vault with the Aztec asset address.
    /// @param asset_ The underlying Aztec asset.
    /// @param stAztec_ The stAztec share token.
    /// @param stakingManager_ The staking manager for delegation messaging.
    /// @param protocolFeeBP_ The protocol fee in basis points.
    /// @param treasuryFeeSplitBP_ The treasury fee split in basis points.
    /// @param governance_ The governance address authorized to upgrade.
    /// @param withdrawalQueue_ The withdrawal queue module address.
    /// @param rewardsVault_ The rewards vault module address.
    /// @param safetyModule_ The safety module address.
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
    ) external;

    /// @notice Deposits assets and mints stAztec shares.
    /// @param assets The amount of assets to deposit.
    /// @param recipient The recipient of the stAztec shares.
    /// @return shares The shares minted to the recipient.
    function deposit(uint256 assets, address recipient) external returns (uint256 shares);

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
        returns (uint256 shares);

    /// @notice Requests a redemption in shares.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the assets.
    /// @return requestId The withdrawal request id.
    function requestRedeem(uint256 shares, address recipient) external returns (uint256 requestId);

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
        returns (uint256 requestId);

    /// @notice Claims a finalized withdrawal request for a controller.
    /// @param owner The request owner.
    /// @return assets The assets claimed for the request.
    function claimActiveRequest(address owner) external returns (uint256 assets);

    /// @notice Claims a finalized withdrawal request by id.
    /// @param requestId The withdrawal request id.
    /// @return assets The assets claimed for the request.
    function claimRequestById(uint256 requestId) external returns (uint256 assets);

    /*//////////////////////////////////////////////////////////////
                      PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses deposits and withdrawals.
    function pause() external;

    /// @notice Unpauses deposits and withdrawals.
    function unpause() external;

    /// @notice Operator-triggered rebalance hook.
    function rebalance() external;

    /// @notice Operator-triggered accounting update hook.
    function updateAccounting() external;

    /// @notice Operator-triggered rewards harvest hook.
    /// @return rewardsDelta The delta amount of rewards (actual balance increase in RewardsVault).
    function harvestRewards() external returns (uint256 rewardsDelta);

    /// @notice Operator-triggered withdrawal finalization hook.
    /// @param available The available assets for withdrawals.
    /// @return used The assets used for finalization.
    function finalizeWithdrawals(uint256 available) external returns (uint256 used);

    /// @notice Sets the protocol fee in basis points.
    /// @param newFeeBP The new fee (0-10000).
    function setProtocolFeeBP(uint256 newFeeBP) external;

    /// @notice Sets the treasury fee split in basis points.
    /// @param newSplitBP The new split (0-10000).
    function setTreasuryFeeSplitBP(uint256 newSplitBP) external;

    /// @notice Sets the governance address.
    /// @param newGovernance The new governance address.
    function setGovernance(address newGovernance) external;

    /// @notice Sets the rewards vault address.
    /// @param newRewardsVault The new rewards vault address.
    function setRewardsVault(IRewardsVault newRewardsVault) external;

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the underlying asset address.
    /// @return The underlying asset address.
    function asset() external view returns (address);

    /// @notice Returns the stAztec share token address.
    /// @return The stAztec share token address.
    function stAztec() external view returns (address);

    /// @notice Returns the staking manager address.
    /// @return The staking manager address.
    function stakingManager() external view returns (address);

    /// @notice Returns the active withdrawal request id for an owner.
    /// @param owner The request owner.
    /// @return requestId The active request id or zero if none.
    function activeRequestId(address owner) external view returns (uint256 requestId);

    /// @notice Returns the recorded owner for a withdrawal request id.
    /// @param requestId The withdrawal request id.
    /// @return owner The request owner.
    function requestOwner(uint256 requestId) external view returns (address owner);

    /// @notice Returns the active withdrawal request for an owner.
    /// @param owner The request owner.
    /// @return request The withdrawal request struct.
    function getActiveWithdrawalRequest(address owner)
        external
        view
        returns (IWithdrawalQueue.WithdrawalRequest memory request);

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

    /// @notice Returns the protocol fee in basis points.
    /// @return The protocol fee BP.
    function protocolFeeBP() external view returns (uint256);

    /// @notice Returns the treasury fee split in basis points.
    /// @return The treasury fee split BP.
    function treasuryFeeSplitBP() external view returns (uint256);
}
