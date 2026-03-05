// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

/// @title IStakingManager
/// @notice Interface for staking delegation and rollup coordination.
/// @author Olla Core contributors
interface IStakingManager {
    /*//////////////////////////////////////////////////////////////
                                  STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Local registry status for attesters.
    enum InternalAttesterStatus {
        Inactive,
        Active,
        Exiting
    }

    /// @notice Attester key information for staking.
    /// @param attester The address that will act as the attester.
    /// @param publicKeyG1 The G1 point of the BLS public key.
    /// @param publicKeyG2 The G2 point of the BLS public key.
    /// @param proofOfPossession Proof that G1 and G2 keys share the same secret.
    struct KeyStore {
        address attester;
        G1Point publicKeyG1;
        G2Point publicKeyG2;
        G1Point proofOfPossession;
    }

    /// @notice Tracks an attester with their originally staked amount and last seen status.
    /// @param attester The attester address.
    /// @param stakedAmount The amount originally staked (activation threshold at stake time).
    /// @param pendingExitAmount The amount added to aggregate pendingUnstakeAmount for this attester.
    /// @param status The local registry status.
    struct AttesterInfo {
        address attester;
        uint256 stakedAmount;
        uint256 pendingExitAmount;
        InternalAttesterStatus status;
    }

    /// @notice Configuration for the staking provider.
    /// @param admin The provider admin address.
    /// @param rewardsRecipient The address to receive sequencer rewards.
    struct ProviderConfig {
        address admin;
        address rewardsRecipient;
    }

    /// @notice Aggregated staking state from on-chain queries.
    /// @param slashingDelta Cumulative slashing delta across rollup snapshots.
    /// @param stakedAmount Total amount in VALIDATING status with effectiveBalance > 0.
    /// @param pendingUnstakeAmount Total amount in exit state, not yet exitable.
    /// @param withdrawableAmount Total amount in exit state, now exitable.
    struct StakingState {
        uint256 slashingDelta;
        uint256 stakedAmount;
        uint256 pendingUnstakeAmount;
        uint256 withdrawableAmount;
    }

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when assets are staked with a attester.
    /// @param attester The attester address.
    /// @param amount The amount staked.
    event StakedWithProvider(address indexed attester, uint256 indexed amount);

    /// @notice Emitted when an unstake is initiated.
    /// @param attester The attester address.
    /// @param amount The amount being unstaked.
    event UnstakeInitiated(address indexed attester, uint256 indexed amount);

    /// @notice Emitted when an unstake is finalized.
    /// @param attester The attester address.
    /// @param amount The amount unstaked.
    event UnstakeFinalized(address indexed attester, uint256 indexed amount);

    /// @notice Emitted when unstaked funds are claimed back to core.
    /// @param amount The amount claimed.
    event UnstakedFundsClaimed(uint256 indexed amount);

    /// @notice Emitted when rewards are harvested.
    /// @param amount The amount harvested.
    event RewardsHarvested(uint256 indexed amount);

    /// @notice Emitted when an attester is removed from the registry.
    /// @param attester The removed attester address.
    event AttesterRemoved(address indexed attester);

    /// @notice Emitted when an attester's state is refreshed.
    /// @param attester The attester address.
    /// @param oldBalance The previous cached balance.
    /// @param newBalance The new balance from rollup.
    event AttesterStateRefreshed(address indexed attester, uint256 indexed oldBalance, uint256 indexed newBalance);

    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an address is zero.
    error StakingManager__ZeroAddress(string param);

    /// @notice Thrown when an amount is zero.
    error StakingManager__ZeroAmount();

    /// @notice Thrown when trying to unstake more than staked.
    error StakingManager__InsufficientStake();

    /// @notice Thrown when there are not enough keys for the stake amount.
    error StakingManager__InsufficientKeys();

    /// @notice Thrown when claimed amount doesn't match expected exit amounts.
    error StakingManager__ClaimAmountMismatch();

    /// @notice Thrown when stake amount is below activation threshold.
    error StakingManager__InsufficientAmount();

    /// @notice Thrown when unstake fails for an attester.
    error StakingManager__UnstakeFailed(address attester);

    /// @notice Thrown when caller is not authorized core.
    error StakingManager__UnauthorizedCore(address caller);

    /// @notice Thrown when a configuration parameter is out of bounds.
    error StakingManager__InvalidParameter();

    /// @notice Thrown when attempting to remove an attester that is still active.
    error StakingManager__RemoveAttesterFailed(address attester);

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the StakingManager behind a proxy.
    /// @param stakingAsset_ The staking asset token.
    /// @param rollupRegistry_ The Aztec rollup registry contract.
    /// @param rewardsAccumulator_ The rewards vault address.
    /// @param core_ The OllaCore contract address.
    /// @param stakingProviderRegistry_ The StakingProviderRegistry contract address.
    /// @param defaultAdmin_ The default admin for role management.
    function initialize(
        IERC20 stakingAsset_,
        address rollupRegistry_,
        address rewardsAccumulator_,
        address core_,
        address stakingProviderRegistry_,
        address defaultAdmin_
    ) external;

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the gas threshold used for bounded rebalance work.
    /// @param threshold The gas threshold to enforce.
    function setGasThreshold(uint256 threshold) external;

    /// @notice Stakes assets using provider attesters.
    /// @param amount The amount requested to stake.
    /// @return stakedAmount The actual amount staked.
    function stake(uint256 amount) external returns (uint256 stakedAmount);

    /// @notice Initiates an unstake with the staking provider.
    /// @dev Only callable by core. Iterates internal active attester set until amount is met.
    /// @param amount The amount to unstake.
    /// @return unstakedAmount The amount initiated for unstake in this call.
    function unstake(uint256 amount) external returns (uint256 unstakedAmount);

    /// @notice Claims matured unstaked funds back to core.
    /// @return received The amount of assets received.
    /// @return exitAmount The amount of finalized exit funds included in received.
    /// @return hasRemainingExits True if there are still attesters in exiting state after finalization.
    function getUnstakedFunds() external returns (uint256 received, uint256 exitAmount, bool hasRemainingExits);

    /// @notice Claims sequencer rewards to RewardsAccumulator.
    /// @return harvested The amount of rewards harvested.
    function harvestRewards() external returns (uint256 harvested);

    /*//////////////////////////////////////////////////////////////
                        PERMISSIONLESS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Refreshes cached state for specific attesters by reading the rollup.
    /// @dev Permissionless -- anyone can call. Reads rollup state (source of truth) and
    ///      delta-updates the aggregate accumulator. Also finalizes exits when exitable.
    ///      Idempotent: calling twice for the same attester in the same block is safe.
    /// @param attesters The attester addresses to refresh.
    function refreshAttesterState(address[] calldata attesters) external;

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the cumulative slashing delta from the rollup.
    /// @dev Only callable by the configured core address.
    /// @return slashingDelta The cumulative slashing delta.
    function getSlashingDelta() external view returns (uint256 slashingDelta);

    /// @notice Returns claimable rewards.
    /// @dev Only callable by the configured core address. Does not actually claim rewards.
    /// @return claimableRewards The total rewards claimalbe to rewards recipient.
    function getClaimableRewards() external view returns (uint256 claimableRewards);

    /// @notice Returns the cached total staked principal.
    /// @return stakedTotal The total staked principal.
    function totalStaked() external view returns (uint256 stakedTotal);

    /// @notice Returns the cached aggregated staking state.
    /// @return state The aggregated staking state.
    function getStakingState() external view returns (StakingState memory state);

    /// @notice Returns the cached total amount pending unstake.
    /// @return pendingUnstakeAmount The total pending unstake amount.
    function pendingUnstakes() external view returns (uint256 pendingUnstakeAmount);

    /// @notice Returns true if any exitable unstake exists from cached state.
    /// @return True if there are unstake exits ready to be finalized.
    function hasExitableUnstakes() external view returns (bool);

    /// @notice Returns the provider configuration.
    /// @dev Delegates to the StakingProviderRegistry.
    /// @return The provider config struct.
    function getProviderConfig() external view returns (ProviderConfig memory);

    /// @notice Returns the number of active attesters.
    /// @return The count of active attesters.
    function getActivatedAttesterCount() external view returns (uint256);

    /// @notice Returns the number of exiting attesters.
    /// @return The count of exiting attesters.
    function getPendingUnstakeCount() external view returns (uint256);

    /// @notice Checks if an attester is exiting.
    /// @param attester The attester address.
    /// @return True if the attester is in the exiting status.
    function isUnstakePending(address attester) external view returns (bool);

    /// @notice Returns the core address.
    /// @return The core contract address.
    function core() external view returns (address);

    /// @notice Returns the staking provider registry address.
    /// @return The staking provider registry contract.
    function stakingProviderRegistry() external view returns (IStakingProviderRegistry);
}
