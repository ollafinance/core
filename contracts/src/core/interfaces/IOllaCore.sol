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

    enum RebalanceStep {
        Harvest,
        PullUnstaked,
        FinalizeWithdrawals,
        InitiateUnstake,
        StakeSurplus,
        ComputeAttesterState,
        Done
    }

    enum RebalancePauseReason {
        None,
        RebalanceStart,
        RebalanceComplete,
        GovernanceOverride
    }

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

    struct RebalanceProgress {
        RebalanceStep step;
        uint256 stakeRemaining;
        uint256 unstakeRemaining;
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
    /// @param owner The share owner that initiated the request.
    /// @param recipient The address receiving the assets.
    /// @param shares The shares burned.
    /// @param assetsExpected The assets expected at request time.
    /// @param exchangeRate The exchange rate locked at request time.
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed owner,
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

    /// @notice Emitted when the target buffer is updated.
    /// @param oldBuffer The old target buffer.
    /// @param newBuffer The new target buffer.
    event TargetBufferedAssetsUpdated(uint256 oldBuffer, uint256 newBuffer);

    /// @notice Emitted when the rebalance gas threshold is updated.
    /// @param oldThreshold The old gas threshold.
    /// @param newThreshold The new gas threshold.
    event RebalanceGasThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when a new governance address is proposed.
    /// @param oldGovernance The current governance address.
    /// @param newGovernance The proposed governance address.
    event GovernanceProposed(address oldGovernance, address newGovernance);

    /// @notice Emitted when the pending governance accepts and becomes active.
    /// @param oldGovernance The previous governance address.
    /// @param newGovernance The new governance address.
    event GovernanceAccepted(address oldGovernance, address newGovernance);

    /// @notice Emitted when a pending governance proposal is cancelled.
    /// @param governance The current governance address.
    /// @param pendingGovernance The cancelled pending governance address.
    event GovernanceProposalCancelled(address governance, address pendingGovernance);

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

    /// @notice Emitted when a rebalance operation completes.
    /// @param rewardsDelta Amount of rewards harvested.
    /// @param finalizedAmount Amount of assets used for withdrawal finalization.
    /// @param stakedAmount Amount of assets staked.
    /// @param resultingBuffer Final buffered assets after rebalance.
    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);

    /// @notice Emitted when unstaked funds are claimed during rebalance.
    /// @param amount The amount of unstaked funds received.
    event UnstakedFundsClaimed(uint256 amount);

    /// @notice Emitted when rewards vault funds are pulled to core during rebalance.
    /// @param amount The amount of rewards vault funds received.
    event RewardsVaultFundsPulled(uint256 amount);

    /// @notice Emitted when withdrawals are finalized.
    /// @param available Available assets.
    /// @param used Used assets.
    event WithdrawalFinalized(uint256 available, uint256 used);

    /// @notice Emitted when the core initiates unstaking to satisfy withdrawals.
    /// @param requested Amount requested to unstake based on pending withdrawals.
    /// @param initiated Amount actually initiated (after pendingUnstakes adjustments).
    event UnstakeInitiated(uint256 requested, uint256 initiated);

    /// @notice Emitted when a withdrawal is claimed via queue.
    /// @param requestId Withdrawal request id.
    /// @param recipient Recipient address.
    /// @param assets Assets claimed.
    event WithdrawalClaimed(uint256 requestId, address recipient, uint256 assets);

    /// @notice Emitted when rewards delta is updated.
    /// @param delta The rewards delta amount.
    event RewardsDelta(uint256 delta);

    /// @notice Emitted when buffered assets are reconciled with the actual balance.
    /// @param delta The amount added to buffered assets.
    /// @param newBufferedAssets The updated buffered assets amount.
    /// @param recipient The recipient that benefits from reconciliation.
    event BufferedAssetsReconciled(uint256 delta, uint256 newBufferedAssets, address indexed recipient);

    /// @notice Emitted when stAztec is recovered from the core.
    /// @param amount The amount recovered.
    /// @param recipient The recipient of the recovered stAztec.
    event StAztecRecovered(uint256 amount, address indexed recipient);

    /// @notice Emitted when the core is paused.
    event Paused();

    /// @notice Emitted when the core is unpaused.
    event Unpaused();

    /// @notice Emitted when the rebalance pause state is updated.
    /// @param paused Whether rebalance pause is active.
    /// @param reason The reason for the pause update.
    event RebalancePauseUpdated(bool paused, RebalancePauseReason reason);

    /// @notice Emitted when an instant redemption is completed.
    /// @param owner The share owner.
    /// @param recipient The address receiving the net assets.
    /// @param shares The shares burned.
    /// @param grossAssets The total assets before fee.
    /// @param fee The fee deducted and sent to treasury.
    /// @param netAssets The net assets transferred to the recipient.
    /// @param exchangeRate The exchange rate used.
    event InstantRedemption(
        address indexed owner,
        address indexed recipient,
        uint256 shares,
        uint256 grossAssets,
        uint256 fee,
        uint256 netAssets,
        uint256 exchangeRate
    );

    /// @notice Emitted when the instant redemption fee is updated.
    /// @param oldFeeBP The previous fee in basis points.
    /// @param newFeeBP The new fee in basis points.
    event InstantRedemptionFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);
    // solhint-enable gas-indexed-events

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a zero address is provided.
    error OllaCore__ZeroAddress(string param);

    /// @notice Thrown when queue request ids are inconsistent.
    error OllaCore__UnexpectedRequestId(uint256 expected, uint256 actual);

    /// @notice Thrown when previewed and finalized amounts mismatch.
    error OllaCore__FinalizeAmountMismatch(uint256 previewed, uint256 finalized);
    error OllaCore__FinalizeInconsistent(uint256 finalizedAmount, uint256 finalizedCount);

    /// @notice Thrown when claimed unstaked funds don't match expected.
    error OllaCore__UnstakedFundsMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when a deposit exceeds the configured cap.
    error OllaCore__DepositCapExceeded(uint256 assets, uint256 totalAssets);

    /// @notice Thrown when deposits are blocked by the safety module pause.
    error OllaCore__SafetyModulePaused();

    /// @notice Thrown when a slashing delta is invalid.
    error OllaCore__InvalidSlashingDelta(uint256 previous, uint256 current);

    /// @notice Thrown when an amount is zero or otherwise invalid.
    error OllaCore__InvalidAmount();

    /// @notice Thrown when a fee basis points value exceeds maximum.
    error OllaCore__InvalidFeeBP(uint256 feeBP);

    /// @notice Thrown when a split basis points value exceeds maximum.
    error OllaCore__InvalidSplitBP(uint256 splitBP);

    /// @notice Thrown when stake operation fails.
    error OllaCore__StakeFailed(uint256 amount);

    /// @notice Thrown when the target buffer is invalid.
    error OllaCore__InvalidTargetBufferedAssets(uint256 newBuffer);

    /// @notice Thrown when rebalance pause blocks an action.
    error OllaCore__RebalancePaused();

    /// @notice Thrown when a rebalance pause override is not allowed.
    error OllaCore__RebalancePauseOverrideNotAllowed();

    /// @notice Thrown when an action requires rebalance completion.
    error OllaCore__RebalanceInProgress();

    /// @notice Thrown when an instant redemption exceeds available liquidity.
    error OllaCore__InsufficientLiquidity(uint256 requested, uint256 available);

    /// @notice Thrown when a governance proposal already exists.
    error OllaCore__PendingGovernanceAlreadySet(address pendingGovernance);

    /// @notice Thrown when a governance proposal is missing.
    error OllaCore__NoPendingGovernance();

    /// @notice Thrown when a caller is not the pending governance.
    error OllaCore__UnauthorizedPendingGovernance(address caller);

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

    /// @notice Claims a finalized withdrawal request by id.
    /// @param requestId The withdrawal request id.
    /// @return assets The assets claimed for the request.
    function claimRequestById(uint256 requestId) external returns (uint256 assets);

    /// @notice Instantly redeems stAztec shares for AZTEC assets.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the net assets.
    /// @return assetsAfterFee The net assets transferred to the recipient.
    function redeem(uint256 shares, address recipient) external returns (uint256 assetsAfterFee);

    /// @notice Instantly redeems stAztec shares for AZTEC assets with a permit signature.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the net assets.
    /// @param deadline The permit deadline timestamp.
    /// @param v The permit signature v.
    /// @param r The permit signature r.
    /// @param s The permit signature s.
    /// @return assetsAfterFee The net assets transferred to the recipient.
    function redeemWithPermit(uint256 shares, address recipient, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 assetsAfterFee);

    /*//////////////////////////////////////////////////////////////
                      PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses deposits and withdrawals.
    function pause() external;

    /// @notice Unpauses deposits and withdrawals.
    function unpause() external;

    /// @notice Forces rebalance pause to end once progress is done.
    function forceRebalanceUnpause() external;

    /// @notice Operator-triggered rebalance hook.
    /// @return rewardsDelta The amount of rewards harvested.
    /// @return finalizedAmount The amount of assets used for withdrawal finalization.
    /// @return stakedAmount The amount of assets staked.
    /// @return resultingBuffer The final buffered assets after rebalance.
    function rebalance()
        external
        returns (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);

    /// @notice Operator-triggered accounting update hook.
    function updateAccounting() external;

    /// @notice Reconciles buffered assets with the actual asset balance.
    /// @return delta The amount added to buffered assets.
    function reconcileBufferedAssets() external returns (uint256 delta);

    /// @notice Sets the protocol fee in basis points.
    /// @param newFeeBP The new fee (0-10000).
    function setProtocolFeeBP(uint256 newFeeBP) external;

    /// @notice Sets the treasury fee split in basis points.
    /// @param newSplitBP The new split (0-10000).
    function setTreasuryFeeSplitBP(uint256 newSplitBP) external;

    /// @notice Proposes a new governance address.
    /// @param newGovernance The proposed governance address.
    function proposeGovernance(address newGovernance) external;

    /// @notice Accepts governance by the pending governance address.
    function acceptGovernance() external;

    /// @notice Cancels a pending governance proposal.
    function cancelGovernanceProposal() external;

    /// @notice Sets the rewards vault address.
    /// @param newRewardsVault The new rewards vault address.
    function setRewardsVault(IRewardsVault newRewardsVault) external;

    /// @notice Sets the target buffer used to reserve liquid assets.
    /// @param newBuffer The new target buffer.
    function setTargetBufferedAssets(uint256 newBuffer) external;

    /// @notice Sets the gas threshold used for rebalance step gating.
    /// @param newThreshold The new gas threshold.
    function setRebalanceGasThreshold(uint256 newThreshold) external;

    /// @notice Sets the instant redemption fee in basis points.
    /// @param newFeeBP The new fee (0-10000).
    function setInstantRedemptionFeeBP(uint256 newFeeBP) external;

    /// @notice Recovers stAztec sent directly to the core.
    /// @param recipient The recipient of the recovered stAztec (defaults to governance if zero).
    /// @param amount The amount of stAztec to recover.
    function recoverStAztec(address recipient, uint256 amount) external;

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

    /// @notice Returns the recorded owner for a withdrawal request id.
    /// @param requestId The withdrawal request id.
    /// @return owner The request owner.
    function requestOwner(uint256 requestId) external view returns (address owner);

    /// @notice Returns the active withdrawal request ids for an owner.
    /// @param owner The request owner.
    /// @return requestIds The active request ids.
    function activeRequestIds(address owner) external view returns (uint256[] memory requestIds);

    /// @notice Returns the governance address.
    /// @return The governance address.
    function governance() external view returns (address);

    /// @notice Returns the pending governance address.
    /// @return The pending governance address.
    function pendingGovernance() external view returns (address);

    /// @notice Returns the withdrawal queue module address.
    /// @return The withdrawal queue address.
    function withdrawalQueue() external view returns (address);

    /// @notice Returns the rewards vault module address.
    /// @return The rewards vault address.
    function rewardsVault() external view returns (address);

    /// @notice Returns the safety module address.
    /// @return The safety module address.
    function safetyModule() external view returns (address);

    /// @notice Returns the target liquid assets buffer.
    /// @return The target buffer.
    function targetBufferedAssets() external view returns (uint256);

    /// @notice Returns the rebalance gas threshold.
    /// @return The gas threshold for rebalance step gating.
    function rebalanceGasThreshold() external view returns (uint256);

    /// @notice Returns the latest accounting report snapshot.
    /// @return The latest report struct.
    function latestReport() external view returns (LatestReport memory);

    /// @notice Returns the current rebalance progress snapshot.
    /// @return The rebalance progress struct.
    function rebalanceProgress() external view returns (RebalanceProgress memory);

    /// @notice Returns whether rebalance pause is active.
    /// @return paused Whether rebalance pause is active.
    function isRebalancePaused() external view returns (bool paused);

    /// @notice Returns the rebalance pause reason code.
    /// @return reason The pause reason code.
    function rebalancePauseReason() external view returns (uint8 reason);

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

    /// @notice Returns the maximum assets currently available for instant redemptions.
    /// @return The unencumbered buffered assets available for instant redemptions.
    function availableForInstantRedemption() external view returns (uint256);

    /// @notice Returns the instant redemption fee in basis points.
    /// @return The instant redemption fee BP.
    function instantRedemptionFeeBP() external view returns (uint256);

    /// @notice Returns the protocol fee in basis points.
    /// @return The protocol fee BP.
    function protocolFeeBP() external view returns (uint256);

    /// @notice Returns the treasury fee split in basis points.
    /// @return The treasury fee split BP.
    function treasuryFeeSplitBP() external view returns (uint256);
}
