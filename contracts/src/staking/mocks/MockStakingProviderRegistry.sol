// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";

/// @title MockStakingProviderRegistry
/// @notice Minimal staking provider registry mock for isolated StakingManager testing.
/// @author Olla Core contributors
contract MockStakingProviderRegistry is IStakingProviderRegistry {
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for staking provider admin to manage keys.
    bytes32 public constant STAKING_PROVIDER_ADMIN_ROLE = keccak256("STAKING_PROVIDER_ADMIN_ROLE");

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The StakingManager contract address.
    address public stakingManager;

    /// @notice Address authorized to perform upgrades.
    address public governance;

    IStakingManager.ProviderConfig private _provider;
    IStakingManager.KeyStore[] private _keyQueue;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address stakingManager_, address providerRewardsRecipient_) {
        stakingManager = stakingManager_;
        _provider = IStakingManager.ProviderConfig({ rewardsRecipient: providerRewardsRecipient_ });
    }

    /*//////////////////////////////////////////////////////////////
                         PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds attester keys to the provider queue.
    /// @param keyStores The attester key stores to add.
    function addKeysToProvider(IStakingManager.KeyStore[] calldata keyStores) external override {
        uint256 length = keyStores.length;
        for (uint256 i; i < length; ++i) {
            _keyQueue.push(keyStores[i]);
        }
        emit KeysAddedToProvider(_extractAttesters(keyStores));
    }

    /// @notice Removes keys from the front of the queue.
    /// @param count The number of keys to remove.
    function dripQueue(uint256 count) external override {
        uint256 queueLength = _keyQueue.length;
        uint256 toDrip = count > queueLength ? queueLength : count;
        for (uint256 i; i < toDrip; ++i) {
            IStakingManager.KeyStore memory keyStore = _keyQueue[0];
            _removeFirstKey();
            emit QueueDripped(keyStore.attester);
        }
    }

    /// @notice Sets the provider rewards recipient address.
    /// @param rewardsRecipient The new rewards recipient.
    function setProviderRewardsRecipient(address rewardsRecipient) external override {
        _provider.rewardsRecipient = rewardsRecipient;
        emit ProviderSet(rewardsRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                        STAKING MANAGER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Dequeues and returns the next attester keystore from the queue.
    /// @return keyStore The dequeued attester keystore.
    function getAttesterKeystore() external override returns (IStakingManager.KeyStore memory keyStore) {
        if (_keyQueue.length == 0) {
            revert StakingProviderRegistry__QueueEmpty();
        }
        keyStore = _keyQueue[0];
        _removeFirstKey();
        return keyStore;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the provider queue length.
    /// @return length The number of keys in the queue.
    function getQueueLength() external view override returns (uint256 length) {
        return _keyQueue.length;
    }

    /// @notice Returns the provider configuration.
    /// @return config The provider config struct.
    function getStakingProviderConfig() external view override returns (IStakingManager.ProviderConfig memory config) {
        return _provider;
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice No-op initializer for mock compatibility.
    function initialize(
        address stakingManager_,
        address providerAdmin_,
        address providerRewardsRecipient_,
        address defaultAdmin_
    ) external pure override {
        stakingManager_;
        providerAdmin_;
        providerRewardsRecipient_;
        defaultAdmin_;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _removeFirstKey() internal {
        uint256 length = _keyQueue.length;
        for (uint256 i; i < length - 1; ++i) {
            _keyQueue[i] = _keyQueue[i + 1];
        }
        _keyQueue.pop();
    }

    function _extractAttesters(IStakingManager.KeyStore[] calldata keyStores) internal pure returns (address[] memory) {
        address[] memory attesters = new address[](keyStores.length);
        for (uint256 i; i < keyStores.length; ++i) {
            attesters[i] = keyStores[i].attester;
        }
        return attesters;
    }
}
