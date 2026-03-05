// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";

/// @title IOllaCore
/// @notice Interface for OllaCore -- orchestration + accounting layer.
/// @dev User-facing vault functions (deposit, redeem, claim) are on IOllaVault.
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
        Done
    }

    struct AccountingState {
        uint256 stakedPrincipal;
        uint256 rewardsAccumulatorBalance;
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

    struct CoreModules {
        IERC20 asset;
        address vault;
        IStAztec stAztec;
        IStakingManager stakingManager;
        IRewardsAccumulator rewardsAccumulator;
        address safetyModule;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // solhint-disable gas-indexed-events
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

    /// @notice Emitted when the safety module address is updated.
    /// @param oldSafetyModule The old safety module address.
    /// @param newSafetyModule The new safety module address.
    event SafetyModuleUpdated(address oldSafetyModule, address newSafetyModule);

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

    /// @notice Emitted when rewards vault funds are pulled during rebalance.
    /// @param amount The amount of rewards vault funds received.
    event RewardsAccumulatorFundsPulled(uint256 amount);

    /// @notice Emitted when withdrawal finalization is executed during rebalance.
    /// @param available Amount of assets available for finalization.
    /// @param finalized Amount of assets actually finalized.
    event WithdrawalFinalized(uint256 available, uint256 finalized);

    /// @notice Emitted when the core initiates unstaking to satisfy withdrawals.
    /// @param requested Amount requested to unstake based on pending withdrawals.
    /// @param initiated Amount actually initiated (after pendingUnstakes adjustments).
    event UnstakeInitiated(uint256 requested, uint256 initiated);

    /// @notice Emitted when a negative gross rewards period is detected during accounting.
    /// @param grossRewardsSigned The signed gross rewards value (negative).
    event NegativeRewardsPeriod(int256 grossRewardsSigned);

    /// @notice Emitted when rewards delta is updated.
    /// @param delta The rewards delta amount.
    event RewardsDelta(uint256 delta);

    /// @notice Emitted when the rebalance state machine is force-reset by governance.
    event RebalanceReset();

    /// @notice Emitted when the rebalance cooldown is updated.
    /// @param oldCooldown The previous cooldown in seconds.
    /// @param newCooldown The new cooldown in seconds.
    event RebalanceCooldownUpdated(uint256 indexed oldCooldown, uint256 indexed newCooldown);

    /// @notice Emitted when the vault address is set.
    /// @param vault The vault contract address.
    event VaultSet(address indexed vault);
    // solhint-enable gas-indexed-events

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a zero address is provided.
    error OllaCore__ZeroAddress(string param);

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

    /// @notice Thrown when a gas threshold value is out of bounds.
    error OllaCore__InvalidGasThreshold(uint256 threshold);

    /// @notice Thrown when stake operation fails.
    error OllaCore__StakeFailed(uint256 amount);

    /// @notice Thrown when the target buffer is invalid.
    error OllaCore__InvalidTargetBufferedAssets(uint256 newBuffer);

    /// @notice Thrown when an action requires rebalance completion.
    error OllaCore__RebalanceInProgress();

    /// @notice Thrown when the new safety module's CORE does not match this contract.
    error OllaCore__InvalidSafetyModule(address safetyModule);

    /// @notice Thrown when the rebalance cooldown has not elapsed.
    /// @param elapsed Seconds since last accounting update.
    /// @param required Required cooldown seconds.
    error OllaCore__RebalanceCooldownActive(uint256 elapsed, uint256 required);

    /// @notice Thrown when a parameter is invalid.
    error OllaCore__InvalidParameter();

    /// @notice Thrown when claimed unstaked funds don't match expected.
    error OllaCore__UnstakedFundsMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when previewed and finalized amounts mismatch.
    error OllaCore__FinalizeAmountMismatch(uint256 previewed, uint256 finalized);

    /// @notice Thrown when finalized amounts are inconsistent with count.
    error OllaCore__FinalizeInconsistent(uint256 finalizedAmount, uint256 finalizedCount);

    /// @notice Thrown when the vault has already been set.
    error OllaCore__VaultAlreadySet();

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the core with orchestration parameters.
    /// @param asset_ The underlying Aztec asset.
    /// @param stAztec_ The stAztec share token (for pricing).
    /// @param stakingManager_ The staking manager for delegation messaging.
    /// @param protocolFeeBP_ The protocol fee in basis points.
    /// @param treasuryFeeSplitBP_ The treasury fee split in basis points.
    /// @param governanceContract_ The OllaGovernance contract address (set as owner).
    /// @param rewardsAccumulator_ The rewards vault module address.
    /// @param safetyModule_ The safety module address.
    function initialize(
        IERC20 asset_,
        IStAztec stAztec_,
        IStakingManager stakingManager_,
        uint256 protocolFeeBP_,
        uint256 treasuryFeeSplitBP_,
        address governanceContract_,
        IRewardsAccumulator rewardsAccumulator_,
        address safetyModule_
    ) external;

    /*//////////////////////////////////////////////////////////////
                      PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses the core.
    function pause() external;

    /// @notice Unpauses the core.
    function unpause() external;

    /// @notice Forces the rebalance state machine to reset to Done.
    function forceRebalanceReset() external;

    /*//////////////////////////////////////////////////////////////
                        PERMISSIONLESS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless rebalance flow.
    /// @return rewardsDelta The amount of rewards harvested.
    /// @return finalizedAmount The amount of assets used for withdrawal finalization.
    /// @return stakedAmount The amount of assets staked.
    /// @return resultingBuffer The final buffered assets after rebalance.
    function rebalance()
        external
        returns (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);

    /// @notice Permissionless accounting update hook.
    function updateAccounting() external;

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time setter for the vault address (handles circular dependency).
    /// @param vault_ The OllaVault contract address.
    function setVault(address vault_) external;

    /// @notice Sets the protocol fee in basis points.
    /// @param newFeeBP The new fee.
    function setProtocolFeeBP(uint256 newFeeBP) external;

    /// @notice Sets the treasury fee split in basis points.
    /// @param newSplitBP The new split.
    function setTreasuryFeeSplitBP(uint256 newSplitBP) external;

    /// @notice Sets the safety module address.
    /// @param newSafetyModule The new safety module address.
    function setSafetyModule(address newSafetyModule) external;

    /// @notice Sets the target buffer used to reserve liquid assets.
    /// @param newBuffer The new target buffer.
    function setTargetBufferedAssets(uint256 newBuffer) external;

    /// @notice Sets the gas threshold used for rebalance step gating.
    /// @param newThreshold The new gas threshold.
    function setRebalanceGasThreshold(uint256 newThreshold) external;

    /// @notice Sets the rebalance cooldown.
    /// @param cooldown_ The new cooldown in seconds.
    function setRebalanceCooldown(uint256 cooldown_) external;

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the underlying asset address.
    /// @return The underlying asset address.
    function asset() external view returns (address);

    /// @notice Returns the OllaVault address.
    /// @return The OllaVault address.
    function vault() external view returns (address);

    /// @notice Returns the stAztec share token address.
    /// @return The stAztec share token address.
    function stAztec() external view returns (address);

    /// @notice Returns the staking manager address.
    /// @return The staking manager address.
    function stakingManager() external view returns (address);

    /// @notice Returns the rewards vault module address.
    /// @return The rewards vault module address.
    function rewardsAccumulator() external view returns (address);

    /// @notice Returns the safety module address.
    /// @return The safety module address.
    function safetyModule() external view returns (address);

    /// @notice Returns the target liquid assets buffer.
    /// @return The target liquid assets buffer.
    function targetBufferedAssets() external view returns (uint256);

    /// @notice Returns the rebalance gas threshold.
    /// @return The rebalance gas threshold.
    function rebalanceGasThreshold() external view returns (uint32);

    /// @notice Returns the latest accounting report snapshot.
    /// @return The latest accounting report snapshot.
    function latestReport() external view returns (LatestReport memory);

    /// @notice Returns the current rebalance progress snapshot.
    /// @return The current rebalance progress snapshot.
    function rebalanceProgress() external view returns (RebalanceProgress memory);

    /// @notice Returns the flow counter snapshots.
    /// @return The flow counter snapshots.
    function flowCounters() external view returns (FlowCounters memory);

    /// @notice Returns the accounting buckets snapshot.
    /// @return The accounting buckets snapshot.
    function accountingState() external view returns (AccountingState memory);

    /// @notice Returns the current total assets held by the protocol.
    /// @return The current total assets held by the protocol.
    function totalAssets() external view returns (uint256);

    /// @notice Returns the current exchange rate in 18-decimal fixed-point units.
    /// @return The current exchange rate in 18-decimal fixed-point units.
    function exchangeRate() external view returns (uint256);

    /// @notice Computes the shares for an asset amount.
    /// @param assets The amount of assets to convert.
    /// @return shares The computed share amount.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Computes the assets for a share amount (rounds down).
    /// @param shares The amount of shares to convert.
    /// @return assets The computed asset amount (rounds down).
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Computes the assets for a share amount (rounds up).
    /// @param shares The amount of shares to convert.
    /// @return assets The computed asset amount (rounds up).
    function convertToAssetsCeil(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the rebalance cooldown in seconds.
    /// @return The rebalance cooldown in seconds.
    function rebalanceCooldown() external view returns (uint32);

    /// @notice Returns the protocol fee in basis points.
    /// @return The protocol fee in basis points.
    function protocolFeeBP() external view returns (uint16);

    /// @notice Returns the treasury fee split in basis points.
    /// @return The treasury fee split in basis points.
    function treasuryFeeSplitBP() external view returns (uint16);
}
