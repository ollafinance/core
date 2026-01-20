// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { AccessControl } from "@oz/access/AccessControl.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IAztecRollupRegistry } from "src/interfaces/IAztecRollupRegistry.sol";
import { IAztecStaking } from "src/interfaces/IAztecStaking.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { Queue, QueueLib } from "src/libraries/QueueLib.sol";

/// @title StakingManager
/// @notice Manages staking delegation, attester keys, and reward harvesting.
/// @author Olla Core contributors
contract StakingManager is IStakingManager, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using QueueLib for Queue;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for OllaCore to call stake/unstake operations.
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    /// @notice Role for staking provider admin to manage keys.
    bytes32 public constant STAKING_PROVIDER_ADMIN_ROLE = keccak256("STAKING_PROVIDER_ADMIN_ROLE");

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The staking asset (AZTEC token).
    IERC20 public immutable STAKING_ASSET;

    /// @notice The Aztec rollup registry contract.
    IAztecRollupRegistry public immutable ROLLUP_REGISTRY;

    /// @notice The rewards vault address.
    address public immutable REWARDS_VAULT;

    /// @notice The OllaCore contract address.
    address public immutable CORE;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev Provider configuration.
    ProviderConfig private _provider;

    /// @dev FIFO queue of attester keys.
    Queue private _providerQueue;

    /// @dev Total staked principal amount.
    uint256 private _totalStakedPrincipal;

    /// @dev Amount pending in unstake requests.
    uint256 private _pendingUnstakes;

    /// @dev List of activated attester addresses.
    address[] private _activatedAttesters;

    /// @dev Mapping from attester to index in _activatedAttesters.
    mapping(address attester => uint256 index) private _attesterIndex;

    /// @dev Mapping to check if an attester is activated.
    mapping(address attester => bool isActivated) private _isActivatedAttester;

    /// @dev List of pending unstake requests.
    UnstakeRequest[] private _pendingUnstakeRequests;

    /// @dev Mapping to check if an attester has a pending unstake.
    mapping(address attester => bool isPending) private _isUnstakePending;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the StakingManager.
    /// @param stakingAsset The staking asset token.
    /// @param rollupRegistry The Aztec rollup registry contract.
    /// @param rewardsVault The rewards vault address.
    /// @param core The OllaCore contract address.
    /// @param providerAdmin The provider admin address.
    /// @param providerRewardsRecipient The provider rewards recipient address.
    /// @param defaultAdmin The default admin for role management.
    constructor(
        IERC20 stakingAsset,
        address rollupRegistry,
        address rewardsVault,
        address core,
        address providerAdmin,
        address providerRewardsRecipient,
        address defaultAdmin
    ) {
        if (address(stakingAsset) == address(0)) {
            revert StakingManager__ZeroAddress();
        }
        if (rollupRegistry == address(0)) revert StakingManager__ZeroAddress();
        if (rewardsVault == address(0)) revert StakingManager__ZeroAddress();
        if (core == address(0)) revert StakingManager__ZeroAddress();
        if (providerAdmin == address(0)) revert StakingManager__ZeroAddress();
        if (defaultAdmin == address(0)) revert StakingManager__ZeroAddress();

        STAKING_ASSET = stakingAsset;
        ROLLUP_REGISTRY = IAztecRollupRegistry(rollupRegistry);
        REWARDS_VAULT = rewardsVault;
        CORE = core;

        _provider = ProviderConfig({ admin: providerAdmin, rewardsRecipient: providerRewardsRecipient });

        _providerQueue.init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(CORE_ROLE, core);
        _grantRole(STAKING_PROVIDER_ADMIN_ROLE, providerAdmin);

        emit ProviderSet(providerAdmin, providerRewardsRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function stake(uint256 amount) external override onlyRole(CORE_ROLE) nonReentrant {
        if (amount == 0) revert StakingManager__ZeroAmount();
        _stakeInternal(amount);
    }

    /// @inheritdoc IStakingManager
    function unStake(uint256 amount) external override onlyRole(CORE_ROLE) nonReentrant {
        if (amount == 0) revert StakingManager__ZeroAmount();
        _unstakeInternal(amount);
    }

    /// @inheritdoc IStakingManager
    function getUnstakedFunds() external override onlyRole(CORE_ROLE) nonReentrant returns (uint256 received) {
        return _claimUnstakedFunds();
    }

    /// @inheritdoc IStakingManager
    function harvestRewards() external override onlyRole(CORE_ROLE) nonReentrant returns (uint256 harvested) {
        // Placeholder: RewardsVault integration deferred to Milestone 5
        // In production, this would call rollup.claimSequencerRewards for each activated attester
        // and forward the rewards to REWARDS_VAULT
        harvested = 0;
        emit RewardsHarvested(harvested);
        return harvested;
    }

    /*//////////////////////////////////////////////////////////////
                        PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function addKeysToProvider(KeyStore[] calldata keyStores) external override onlyRole(STAKING_PROVIDER_ADMIN_ROLE) {
        uint256 length = keyStores.length;
        if (length == 0) revert StakingManager__ZeroAmount();

        address[] memory attesters = new address[](length);
        for (uint256 i; i < length; ++i) {
            // Return value intentionally ignored - enqueue always succeeds for valid inputs
            // slither-disable-next-line unused-return
            _providerQueue.enqueue(keyStores[i]);
            attesters[i] = keyStores[i].attester;
        }

        emit KeysAddedToProvider(attesters);
    }

    /// @inheritdoc IStakingManager
    function dripQueue(uint256 count) external override onlyRole(STAKING_PROVIDER_ADMIN_ROLE) {
        if (count == 0) revert StakingManager__ZeroAmount();
        uint256 queueLength = _providerQueue.length();
        if (queueLength == 0) revert StakingManager__QueueEmpty();

        uint256 toDrip = count > queueLength ? queueLength : count;
        for (uint256 i; i < toDrip; ++i) {
            KeyStore memory keyStore = _providerQueue.dequeue();
            emit QueueDripped(keyStore.attester);
        }
    }

    /// @inheritdoc IStakingManager
    function setProviderRewardsRecipient(address rewardsRecipient)
        external
        override
        onlyRole(STAKING_PROVIDER_ADMIN_ROLE)
    {
        if (rewardsRecipient == address(0)) {
            revert StakingManager__ZeroAddress();
        }
        _provider.rewardsRecipient = rewardsRecipient;
        emit ProviderSet(_provider.admin, rewardsRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256) {
        return _totalStakedPrincipal;
    }

    /// @inheritdoc IStakingManager
    function getPendingUnstakes() external view override returns (uint256) {
        return _pendingUnstakes;
    }

    /// @inheritdoc IStakingManager
    function getQueueLength() external view override returns (uint256) {
        return _providerQueue.length();
    }

    /// @inheritdoc IStakingManager
    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return _provider;
    }

    /// @inheritdoc IStakingManager
    function getActivatedAttesterCount() external view override returns (uint256) {
        return _activatedAttesters.length;
    }

    /// @inheritdoc IStakingManager
    function getPendingUnstakeCount() external view override returns (uint256) {
        return _pendingUnstakeRequests.length;
    }

    /// @inheritdoc IStakingManager
    function isUnstakePending(address attester) external view override returns (bool) {
        return _isUnstakePending[attester];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal stake implementation.
    /// @param amount The amount to stake.
    // slither-disable-start divide-before-multiply
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-no-eth
    function _stakeInternal(uint256 amount) internal {
        // Get canonical rollup from registry
        address rollupAddress = ROLLUP_REGISTRY.getCanonicalRollup();
        IAztecStaking rollup = IAztecStaking(rollupAddress);

        // Get activation threshold from rollup
        uint256 activationThreshold = rollup.getActivationThreshold();

        // Calculate how many attesters we can stake to
        // Note: Division before multiplication is intentional - we want to truncate to whole attesters
        uint256 attestersToStakeTo = amount / activationThreshold;
        if (attestersToStakeTo == 0) {
            revert StakingManager__InsufficientAmount();
        }

        // Check we have enough keys
        uint256 availableKeys = _providerQueue.length();
        if (availableKeys == 0) {
            revert StakingManager__InsufficientKeys();
        }

        // Limit attesters to available keys
        if (attestersToStakeTo > availableKeys) {
            attestersToStakeTo = availableKeys;
        }

        // Calculate actual stake amount (intentional truncation to whole attesters)
        uint256 actualStakeAmount = attestersToStakeTo * activationThreshold;
        // Transfer assets from core to this contract
        // Note: CORE is an immutable trusted address set at construction, not arbitrary
        // slither-disable-next-line arbitrary-send-erc20
        STAKING_ASSET.safeTransferFrom(CORE, address(this), actualStakeAmount);

        // Approve rollup to spend
        STAKING_ASSET.forceApprove(rollupAddress, actualStakeAmount);

        // Update state before external calls (CEI pattern for principal tracking)
        _totalStakedPrincipal += actualStakeAmount;

        // Stake each attester (loop over external calls is intentional for batch operations)
        for (uint256 i; i < attestersToStakeTo; ++i) {
            // Dequeue a key
            KeyStore memory keyStore = _providerQueue.dequeue();

            // Deposit to rollup
            rollup.deposit(
                keyStore.attester,
                address(this), // StakingManager is the withdrawer
                keyStore.publicKeyG1,
                keyStore.publicKeyG2,
                keyStore.proofOfPossession,
                true // moveWithLatestRollup
            );

            // Track activated attester
            _addActivatedAttester(keyStore.attester);

            emit StakedWithProvider(keyStore.attester, activationThreshold);
        }

        // Reset approval
        STAKING_ASSET.forceApprove(rollupAddress, 0);
    }

    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop
    // slither-disable-end divide-before-multiply

    /// @dev Internal unstake implementation.
    /// @param amount The amount to unstake.
    // slither-disable-start divide-before-multiply
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-no-eth
    function _unstakeInternal(uint256 amount) internal {
        // Check we have enough staked (accounting for pending unstakes)
        uint256 availableToUnstake = _totalStakedPrincipal - _pendingUnstakes;
        if (amount > availableToUnstake) {
            revert StakingManager__InsufficientStake();
        }

        // Get canonical rollup from registry
        address rollupAddress = ROLLUP_REGISTRY.getCanonicalRollup();
        IAztecStaking rollup = IAztecStaking(rollupAddress);

        uint256 activationThreshold = rollup.getActivationThreshold();
        // Round up to get number of attesters to unstake from
        uint256 attestersToUnstake = (amount + activationThreshold - 1) / activationThreshold;

        // Limit to available activated attesters
        uint256 availableAttesters = _activatedAttesters.length;
        if (attestersToUnstake > availableAttesters) {
            attestersToUnstake = availableAttesters;
        }

        uint256 actualUnstakeAmount = 0;

        // Update principal state before external calls (CEI pattern)
        uint256 expectedUnstakeAmount = attestersToUnstake * activationThreshold;
        _totalStakedPrincipal -= expectedUnstakeAmount;
        _pendingUnstakes += expectedUnstakeAmount;

        // Loop over attesters to unstake (intentional batch operation)
        for (uint256 i; i < attestersToUnstake; ++i) {
            // Get last activated attester (more efficient removal)
            address attester = _activatedAttesters[_activatedAttesters.length - 1];

            // Initiate withdrawal on rollup (return value intentionally ignored - we track state ourselves)
            // slither-disable-next-line unused-return
            rollup.initiateWithdraw(attester, address(this));

            // Track pending unstake
            _pendingUnstakeRequests.push(
                UnstakeRequest({ attester: attester, amount: activationThreshold, initiatedAt: block.timestamp })
            );
            _isUnstakePending[attester] = true;

            // Remove from activated attesters
            _removeActivatedAttester(attester);

            actualUnstakeAmount += activationThreshold;

            emit UnstakeInitiated(attester, activationThreshold);
        }
    }

    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop
    // slither-disable-end divide-before-multiply

    /// @dev Internal claim unstaked funds implementation.
    /// @return claimed The amount claimed.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-no-eth
    function _claimUnstakedFunds() internal returns (uint256 claimed) {
        // Get canonical rollup from registry
        address rollupAddress = ROLLUP_REGISTRY.getCanonicalRollup();
        IAztecStaking rollup = IAztecStaking(rollupAddress);

        uint256 i = 0;
        claimed = 0;

        // Loop over pending requests to claim matured withdrawals (intentional batch operation)
        while (i < _pendingUnstakeRequests.length) {
            UnstakeRequest memory request = _pendingUnstakeRequests[i];

            // Try to finalize this withdrawal
            // solhint-disable-next-line no-empty-blocks
            try rollup.finalizeWithdraw(request.attester) {
                claimed += request.amount;
                _isUnstakePending[request.attester] = false;

                // Remove from pending list (swap and pop)
                uint256 lastIndex = _pendingUnstakeRequests.length - 1;
                if (i != lastIndex) {
                    _pendingUnstakeRequests[i] = _pendingUnstakeRequests[lastIndex];
                }
                _pendingUnstakeRequests.pop();

                // Don't increment i, we moved a new element to this position
            } catch {
                // Withdrawal not ready yet, skip
                ++i;
            }
        }

        if (claimed > 0) {
            _pendingUnstakes -= claimed;
            // Transfer claimed funds to core
            STAKING_ASSET.safeTransfer(CORE, claimed);
            emit UnstakedFundsClaimed(claimed);
        }

        return claimed;
    }

    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    /// @dev Adds an attester to the activated attesters list.
    /// @param attester The attester address.
    function _addActivatedAttester(address attester) internal {
        if (!_isActivatedAttester[attester]) {
            _attesterIndex[attester] = _activatedAttesters.length;
            _activatedAttesters.push(attester);
            _isActivatedAttester[attester] = true;
        }
    }

    /// @dev Removes an attester from the activated attesters list.
    /// @param attester The attester address.
    function _removeActivatedAttester(address attester) internal {
        if (_isActivatedAttester[attester]) {
            uint256 index = _attesterIndex[attester];
            uint256 lastIndex = _activatedAttesters.length - 1;

            if (index != lastIndex) {
                address lastAttester = _activatedAttesters[lastIndex];
                _activatedAttesters[index] = lastAttester;
                _attesterIndex[lastAttester] = index;
            }

            _activatedAttesters.pop();
            delete _attesterIndex[attester];
            _isActivatedAttester[attester] = false;
        }
    }
}
