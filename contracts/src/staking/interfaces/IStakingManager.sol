// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

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

    /// @notice Tracks an attester with their originally staked amount.
    /// @param attester The attester address.
    /// @param stakedAmount The amount originally staked (activation threshold at stake time).
    struct AttesterStake {
        address attester;
        uint256 stakedAmount;
    }

    /// @notice Configuration for the staking provider.
    /// @param admin The provider admin address.
    /// @param rewardsRecipient The address to receive sequencer rewards.
    struct ProviderConfig {
        address admin;
        address rewardsRecipient;
    }

    /// @notice Aggregated staking state from on-chain queries.
    /// @param stakedAmount Total amount in VALIDATING status with effectiveBalance > 0.
    /// @param pendingUnstakeAmount Total amount in exit state, not yet exitable.
    /// @param withdrawableAmount Total amount in exit state, now exitable.
    struct StakingState {
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

    /// @notice Emitted when rewards are claimed for a specific attester.
    /// @param attester The attester address.
    /// @param amount The amount of rewards claimed.
    event AttesterRewardsClaimed(address indexed attester, uint256 indexed amount);

    /// @notice Emitted when reward claim fails for an attester.
    /// @param attester The attester address.
    /// @param reason The failure reason.
    event RewardClaimFailed(address indexed attester, string reason);

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

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the StakingManager behind a proxy.
    /// @param stakingAsset_ The staking asset token.
    /// @param rollupRegistry_ The Aztec rollup registry contract.
    /// @param rewardsVault_ The rewards vault address.
    /// @param core_ The OllaCore contract address.
    /// @param stakingProviderRegistry_ The StakingProviderRegistry contract address.
    /// @param defaultAdmin_ The default admin for role management.
    function initialize(
        IERC20 stakingAsset_,
        address rollupRegistry_,
        address rewardsVault_,
        address core_,
        address stakingProviderRegistry_,
        address defaultAdmin_
    ) external;

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Stakes assets using provider attesters.
    /// @param amount The amount requested to stake.
    /// @return stakedAmount The actual amount staked.
    function stake(uint256 amount) external returns (uint256 stakedAmount);

    /// @notice Initiates an unstake with the staking provider.
    /// @param amount The amount to unstake.
    function unstake(uint256 amount) external;

    /// @notice Syncs the activated attesters with the rollup and moves them to pendingUnstake if needed.
    /// @dev Since attesters can exit due to external reasons activatedAtesters is not guranteed to be in sync.
    function cleanActivatedAttesters() external;

    /// @notice Claims matured unstaked funds back to core.
    /// @return received The amount of assets received.
    function getUnstakedFunds() external returns (uint256 received);

    /// @notice Claims sequencer rewards to RewardsVault.
    /// @return harvested The amount of rewards harvested.
    function harvestRewards() external returns (uint256 harvested);

    /// @notice Returns the cumulative slashing delta from the rollup.
    /// @dev Only callable by the configured core address.
    /// @return slashingDelta The cumulative slashing delta.
    function getSlashingDelta() external returns (uint256 slashingDelta);

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns claimable rewards.
    /// @dev Only callable by the configured core address. Does not actually claim rewards.
    /// @return claimableRewards The total rewards claimalbe to rewards recipient.
    function getClaimableRewards() external view returns (uint256 claimableRewards);

    /// @notice Returns the total staked principal across validator states.
    /// @return stakedTotal The total staked principal.
    function totalStaked() external view returns (uint256 stakedTotal);

    /// @notice Returns the current staking state by querying the rollup.
    /// @dev Iterates through all attesters and queries getAttesterView for each.
    /// @return state The aggregated staking state.
    function getStakingState() external view returns (StakingState memory state);

    /// @notice Returns the total amount pending unstake across the rollup.
    /// @return pendingUnstakeAmount The total pending unstake amount.
    function pendingUnstakes() external view returns (uint256 pendingUnstakeAmount);

    /// @notice Returns the provider configuration.
    /// @dev Delegates to the StakingProviderRegistry.
    /// @return The provider config struct.
    function getProviderConfig() external view returns (ProviderConfig memory);

    /// @notice Returns the number of activated attesters.
    /// @return The count of activated attesters.
    function getActivatedAttesterCount() external view returns (uint256);

    /// @notice Returns the number of pending unstake requests.
    /// @return The count of pending requests.
    function getPendingUnstakeCount() external view returns (uint256);

    /// @notice Checks if an attester has a pending unstake.
    /// @param attester The attester address.
    /// @return True if unstake is pending.
    function isUnstakePending(address attester) external view returns (bool);

    /// @notice Returns the core address.
    /// @return The core contract address.
    function core() external view returns (address);

    /// @notice Returns the staking provider registry address.
    /// @return The staking provider registry contract.
    function stakingProviderRegistry() external view returns (IStakingProviderRegistry);
}
