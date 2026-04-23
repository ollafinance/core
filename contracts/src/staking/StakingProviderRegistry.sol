// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { RolesLib } from "src/shared/RolesLib.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { Queue, QueueLib } from "src/staking/libraries/QueueLib.sol";

/// @title StakingProviderRegistry
/// @notice Manages staking provider configuration and attester key queue.
/// @author Olla Core contributors
contract StakingProviderRegistry is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IStakingProviderRegistry
{
    using QueueLib for Queue;

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for staking provider admin to manage keys.
    bytes32 public constant STAKING_PROVIDER_ADMIN_ROLE = RolesLib.STAKING_PROVIDER_ADMIN_ROLE;

    /*//////////////////////////////////////////////////////////////
                                 IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                                   STATE
    //////////////////////////////////////////////////////////////*/

    // Storage layout (v1): do not reorder or remove variables.
    // - Only append new variables above `__gap` and reduce its length accordingly.
    // - This contract is used behind an ERC1967/UUPS proxy; layout must remain upgrade-safe.

    /// @notice The StakingManager contract address.
    address public stakingManager;

    /// @dev Provider configuration.
    IStakingManager.ProviderConfig private _provider;

    /// @dev FIFO queue of attester keys.
    Queue private _providerQueue;

    /// @dev Tracks attester addresses currently in the queue to prevent duplicate enqueuing.
    mapping(address attester => bool inQueue) private _registeredAttesters;

    /// @notice Governance contract authorized to perform UUPS upgrades.
    address public governanceUpgradeAuthority;

    /// @notice Storage gap for future upgrades.
    /// @dev When adding new state variables, append them above this gap and reduce its length
    ///      by the number of slots consumed. Target: 50 gap slots across all upgradeable contracts.
    // slither-disable-next-line unused-state
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                                  MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyStakingManager() {
        if (msg.sender != stakingManager) {
            revert StakingProviderRegistry__UnauthorizedStakingManager(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingProviderRegistry
    function initialize(
        address stakingManager_,
        address providerAdmin_,
        address providerRewardsRecipient_,
        address defaultAdmin_
    ) external override initializer {
        if (stakingManager_ == address(0)) {
            revert StakingProviderRegistry__ZeroAddress("stakingManager");
        }
        if (providerAdmin_ == address(0)) {
            revert StakingProviderRegistry__ZeroAddress("providerAdmin");
        }
        if (providerRewardsRecipient_ == address(0)) {
            revert StakingProviderRegistry__ZeroAddress("providerRewardsRecipient");
        }
        if (defaultAdmin_ == address(0)) {
            revert StakingProviderRegistry__ZeroAddress("defaultAdmin");
        }

        __AccessControl_init();

        stakingManager = stakingManager_;
        _provider = IStakingManager.ProviderConfig({ rewardsRecipient: providerRewardsRecipient_ });
        governanceUpgradeAuthority = defaultAdmin_;

        _providerQueue.init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin_);
        _grantRole(STAKING_PROVIDER_ADMIN_ROLE, providerAdmin_);

        emit ProviderSet(providerRewardsRecipient_);
    }

    /*//////////////////////////////////////////////////////////////
                         PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingProviderRegistry
    function addKeysToProvider(IStakingManager.KeyStore[] calldata keyStores)
        external
        override
        onlyRole(STAKING_PROVIDER_ADMIN_ROLE)
    {
        uint256 length = keyStores.length;
        if (length == 0) revert StakingProviderRegistry__ZeroAmount();

        address[] memory attesters = new address[](length);
        for (uint256 i; i < length; ++i) {
            address attester = keyStores[i].attester;
            if (_registeredAttesters[attester]) {
                revert StakingProviderRegistry__DuplicateAttester(attester);
            }
            _registeredAttesters[attester] = true;
            // Return value intentionally ignored - enqueue always succeeds for valid inputs
            // slither-disable-next-line unused-return
            _providerQueue.enqueue(keyStores[i]);
            attesters[i] = attester;
        }

        emit KeysAddedToProvider(attesters);
    }

    /// @inheritdoc IStakingProviderRegistry
    function dripQueue(uint256 count) external override onlyRole(STAKING_PROVIDER_ADMIN_ROLE) {
        if (count == 0) revert StakingProviderRegistry__ZeroAmount();
        uint256 queueLength = _providerQueue.length();
        if (queueLength == 0) revert StakingProviderRegistry__QueueEmpty();

        uint256 toDrip = count > queueLength ? queueLength : count;
        for (uint256 i; i < toDrip; ++i) {
            IStakingManager.KeyStore memory keyStore = _providerQueue.dequeue();
            _registeredAttesters[keyStore.attester] = false;
            emit QueueDripped(keyStore.attester);
        }
    }

    /// @inheritdoc IStakingProviderRegistry
    function setProviderRewardsRecipient(address rewardsRecipient)
        external
        override
        onlyRole(STAKING_PROVIDER_ADMIN_ROLE)
    {
        if (rewardsRecipient == address(0)) {
            revert StakingProviderRegistry__ZeroAddress("rewardsRecipient");
        }
        _provider.rewardsRecipient = rewardsRecipient;
        emit ProviderSet(rewardsRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                        STAKING MANAGER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingProviderRegistry
    function getAttesterKeystore()
        external
        override
        onlyStakingManager
        nonReentrant
        returns (IStakingManager.KeyStore memory keyStore)
    {
        if (_providerQueue.length() == 0) revert StakingProviderRegistry__QueueEmpty();
        keyStore = _providerQueue.dequeue();
        _registeredAttesters[keyStore.attester] = false;
        return keyStore;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingProviderRegistry
    function getQueueLength() external view override returns (uint256) {
        return _providerQueue.length();
    }

    /// @inheritdoc IStakingProviderRegistry
    function getStakingProviderConfig() external view override returns (IStakingManager.ProviderConfig memory) {
        return _provider;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != governanceUpgradeAuthority) {
            revert StakingProviderRegistry__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert StakingProviderRegistry__ZeroAddress("newImplementation");
        }
    }
}
