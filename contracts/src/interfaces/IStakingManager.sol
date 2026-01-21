// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

// Import BN254 types - local definitions compatible with Aztec protocol
import { G1Point, G2Point } from "src/libraries/BN254Lib.sol";

/// @title IStakingManager
/// @notice Interface for staking delegation and attester key management.
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

    /// @notice Configuration for the staking provider.
    /// @param admin The provider admin address.
    /// @param rewardsRecipient The address to receive sequencer rewards.
    struct ProviderConfig {
        address admin;
        address rewardsRecipient;
    }

    /// @notice Tracks a pending unstake request.
    /// @param attester The attester address being unstaked.
    /// @param amount The amount being unstaked.
    /// @param initiatedAt The timestamp when unstake was initiated.
    /// @dev Kept for interface compatibility but not used in _pendingUnstakeRequests.
    struct UnstakeRequest {
        address attester;
        uint256 amount;
        uint256 initiatedAt;
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

    /// @notice Emitted when a provider is configured.
    /// @param admin The provider admin address.
    /// @param rewardsRecipient The rewards recipient address.
    event ProviderSet(address indexed admin, address indexed rewardsRecipient);

    /// @notice Emitted when attester keys are added to the queue.
    /// @param attesters The attester addresses of the added keys.
    event KeysAddedToProvider(address[] attesters);

    /// @notice Emitted when assets are staked with a attester.
    /// @param attester The attester address.
    /// @param amount The amount staked.
    event StakedWithProvider(address indexed attester, uint256 amount);

    /// @notice Emitted when an unstake is initiated.
    /// @param attester The attester address.
    /// @param amount The amount being unstaked.
    event UnstakeInitiated(address indexed attester, uint256 amount);

    //  @notice Emitted when an unstake is finalized.
    //  @param attester The attester address.
    //  @param amount The amount unstaked.
    event UnstakeFinalized(address indexed attester, uint256 amount);

    /// @notice Emitted when unstaked funds are claimed back to core.
    /// @param amount The amount claimed.
    event UnstakedFundsClaimed(uint256 amount);

    /// @notice Emitted when rewards are harvested.
    /// @param amount The amount harvested.
    event RewardsHarvested(uint256 amount);

    /// @notice Emitted when keys are removed from the queue.
    /// @param attester The attester address of the removed key.
    event QueueDripped(address indexed attester);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an address is zero.
    error StakingManager__ZeroAddress(string param);

    /// @notice Thrown when an amount is zero.
    error StakingManager__ZeroAmount();

    /// @notice Thrown when trying to unstake more than staked.
    error StakingManager__InsufficientStake();

    /// @notice Thrown when the key queue is empty.
    error StakingManager__QueueEmpty();

    /// @notice Thrown when there are not enough keys for the stake amount.
    error StakingManager__InsufficientKeys();

    /// @notice Thrown when claimed amount doesn't match expected exit amounts.
    error StakingManager__ClaimAmountMismatch();

    /// @notice Thrown when stake amount is below activation threshold.
    error StakingManager__InsufficientAmount();

    /// @notice Thrown when unstake fails for an attester.
    error StakingManager__UnstakeFailed(address attester);

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Stakes assets with the staking provider.
    /// @param amount The amount to stake.
    function stake(uint256 amount) external;

    /// @notice Initiates an unstake with the staking provider.
    /// @param amount The amount to unstake.
    function unstake(uint256 amount) external;

    // @notice Syncs the activated attesters with the rollup and moves them to pendingUnstake if needed.
    // @dev Since attesters can exit due to external reasons activatedAtesters is not guranteed to be in sync.
    function cleanActivatedAttesters() external;

    /// @notice Claims matured unstaked funds back to core.
    /// @return received The amount of assets received.
    function getUnstakedFunds() external returns (uint256 received);

    /// @notice Claims sequencer rewards to RewardsVault.
    /// @return harvested The amount of rewards harvested.
    function harvestRewards() external returns (uint256 harvested);

    /*//////////////////////////////////////////////////////////////
                        PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds attester keys to the provider queue.
    /// @param keyStores The attester key stores to add.
    function addKeysToProvider(KeyStore[] calldata keyStores) external;

    /// @notice Removes keys from the front of the queue.
    /// @param count The number of keys to remove.
    function dripQueue(uint256 count) external;

    /// @notice Sets the provider rewards recipient address.
    /// @param rewardsRecipient The new rewards recipient.
    function setProviderRewardsRecipient(address rewardsRecipient) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current staking state by querying the rollup.
    /// @dev Iterates through all attesters and queries getAttesterView for each.
    /// @return state The aggregated staking state.
    function getStakingState() external view returns (StakingState memory state);

    /// @notice Returns the provider queue length.
    /// @return The number of keys in the queue.
    function getQueueLength() external view returns (uint256);

    /// @notice Returns the provider configuration.
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
}
