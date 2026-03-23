// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

/// @title IStakingProviderRegistry
/// @notice Interface for staking provider configuration and attester key queue management.
/// @author Olla Core contributors
interface IStakingProviderRegistry {
    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the provider rewards recipient is updated.
    /// @param rewardsRecipient The rewards recipient address.
    event ProviderSet(address indexed rewardsRecipient);

    /// @notice Emitted when attester keys are added to the queue.
    /// @param attesters The attester addresses of the added keys.
    event KeysAddedToProvider(address[] attesters);

    /// @notice Emitted when keys are removed from the queue.
    /// @param attester The attester address of the removed key.
    event QueueDripped(address indexed attester);

    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an address is zero.
    error StakingProviderRegistry__ZeroAddress(string param);

    /// @notice Thrown when an amount is zero.
    error StakingProviderRegistry__ZeroAmount();

    /// @notice Thrown when the key queue is empty.
    error StakingProviderRegistry__QueueEmpty();

    /// @notice Thrown when caller is not the authorized staking manager.
    error StakingProviderRegistry__UnauthorizedStakingManager(address caller);

    /// @notice Thrown when a caller is not authorized governance.
    error StakingProviderRegistry__UnauthorizedGovernance(address caller);

    /// @notice Thrown when an attester key is already in the queue.
    error StakingProviderRegistry__DuplicateAttester(address attester);

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the StakingProviderRegistry behind a proxy.
    /// @param stakingManager_ The StakingManager contract address.
    /// @param providerAdmin_ The provider admin address.
    /// @param providerRewardsRecipient_ The provider rewards recipient address.
    /// @param defaultAdmin_ The default admin for role management.
    function initialize(
        address stakingManager_,
        address providerAdmin_,
        address providerRewardsRecipient_,
        address defaultAdmin_
    ) external;

    /*//////////////////////////////////////////////////////////////
                         PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds attester keys to the provider queue.
    /// @param keyStores The attester key stores to add.
    function addKeysToProvider(IStakingManager.KeyStore[] calldata keyStores) external;

    /// @notice Removes keys from the front of the queue.
    /// @param count The number of keys to remove.
    function dripQueue(uint256 count) external;

    /// @notice Sets the provider rewards recipient address.
    /// @param rewardsRecipient The new rewards recipient.
    function setProviderRewardsRecipient(address rewardsRecipient) external;

    /*//////////////////////////////////////////////////////////////
                        STAKING MANAGER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Dequeues and returns the next attester keystore from the queue.
    /// @dev Only callable by the configured staking manager address.
    /// @return keyStore The dequeued attester keystore.
    function getAttesterKeystore() external returns (IStakingManager.KeyStore memory keyStore);

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the staking manager address.
    /// @return The staking manager contract address.
    function stakingManager() external view returns (address);

    /// @notice Returns the provider queue length.
    /// @return The number of keys in the queue.
    function getQueueLength() external view returns (uint256);

    /// @notice Returns the provider configuration.
    /// @return The provider config struct.
    function getStakingProviderConfig() external view returns (IStakingManager.ProviderConfig memory);
}
