// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { AccessControl } from "@oz/access/AccessControl.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IAztecRollupRegistry } from "src/interfaces/IAztecRollupRegistry.sol";
import { IAztecStaking } from "src/interfaces/IAztecStaking.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { AttesterView, Status, Timestamp } from "src/libraries/AztecTypes.sol";
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

    /// @dev List of activated attester addresses.
    address[] private _activatedAttesters;

    /// @dev Mapping from attester to index in _activatedAttesters.
    mapping(address attester => uint256 index) private _attesterIndex;

    /// @dev Mapping to check if an attester is activated.
    mapping(address attester => bool isActivated) private _isActivatedAttester;

    /// @dev List of pending unstake attester addresses.
    /// @dev Only stores addresses; amounts are queried from rollup when needed.
    address[] private _pendingUnstakeRequests;

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
    // slither-disable-next-line calls-loop,timestamp
    function getStakingState() external view override returns (StakingState memory state) {
        address rollupAddress = ROLLUP_REGISTRY.getCanonicalRollup();
        IAztecStaking rollup = IAztecStaking(rollupAddress);

        // Iterate through activated attesters
        uint256 activatedLength = _activatedAttesters.length;
        for (uint256 i; i < activatedLength; ++i) {
            address attester = _activatedAttesters[i];
            AttesterView memory view_ = rollup.getAttesterView(attester);

            if (view_.status == Status.VALIDATING && view_.effectiveBalance > 0) {
                state.stakedAmount += view_.effectiveBalance;
            }

            // Handle attesters that may have been externally exited
            //   likely only ZOMBIE, EXITING "should" not happen externally
            if (view_.exit.exists) {
                if (Timestamp.unwrap(view_.exit.exitableAt) > block.timestamp) {
                    state.pendingUnstakeAmount += view_.exit.amount;
                } else {
                    state.withdrawableAmount += view_.exit.amount;
                }
            }
        }

        // Iterate through pending unstake requests
        uint256 pendingLength = _pendingUnstakeRequests.length;
        for (uint256 i; i < pendingLength; ++i) {
            address attester = _pendingUnstakeRequests[i];
            AttesterView memory view_ = rollup.getAttesterView(attester);

            // NOTE: this should not be needed, because we will always claim matured exits and remove from _pendingUnstakeRequests atomically
            if (view_.exit.exists) {
                if (Timestamp.unwrap(view_.exit.exitableAt) > block.timestamp) {
                    state.pendingUnstakeAmount += view_.exit.amount;
                } else {
                    state.withdrawableAmount += view_.exit.amount;
                }
            }
        }

        return state;
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
    /// @dev Uses single-loop logic that breaks when enough funds are unstaked.
    /// @param amount The amount to unstake.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-no-eth
    function _unstakeInternal(uint256 amount) internal {
        // Get canonical rollup from registry
        address rollupAddress = ROLLUP_REGISTRY.getCanonicalRollup();
        IAztecStaking rollup = IAztecStaking(rollupAddress);

        uint256 totalUnstakedAmount = 0;
        uint256 i = 0;

        // Iterate through activated attesters
        while (i < _activatedAttesters.length) {
            address attester = _activatedAttesters[i];
            AttesterView memory view_ = rollup.getAttesterView(attester);

            // Skip if not validating or zero balance (could be slashed to zero)
            if (view_.status != Status.VALIDATING || view_.effectiveBalance == 0) {
                ++i;
                // TODO: Consider removing from activated list if not validating? (and potentially adding to _pendingUnstakeRequests)
                continue;
            }

            // Initiate withdrawal on rollup
            // WARNING: With Aztec version 3.0.1 only true is returned, so we ignore it here.
            // slither-disable-next-line unused-return
            rollup.initiateWithdraw(attester, address(this));

            // TODO: evaluate if this is needed, or if we could just use view_.effectiveBalance directly
            // Query again to get actual exit.amount (should match effectiveBalance at time of initiation)
            view_ = rollup.getAttesterView(attester);
            uint256 exitAmount = view_.exit.amount;

            // Update tracking
            totalUnstakedAmount += exitAmount;

            // Move attester from activated to pending (swap-and-pop, don't increment i)
            _removeActivatedAttester(attester);
            _pendingUnstakeRequests.push(attester);
            _isUnstakePending[attester] = true;

            emit UnstakeInitiated(attester, exitAmount);

            // Check if we've unstaked enough
            if (totalUnstakedAmount >= amount) {
                break;
            }
            // Note: Don't increment i since _removeActivatedAttester uses swap-and-pop
        }

        // Verify we unstaked enough
        if (totalUnstakedAmount < amount) {
            revert StakingManager__InsufficientStake();
        }
    }

    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    /// @dev Internal claim unstaked funds implementation.
    /// @dev Validates that sumOfExitAmounts matches the actual claimed amount.
    /// @return claimed The amount claimed.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-no-eth
    function _claimUnstakedFunds() internal returns (uint256 claimed) {
        // Get canonical rollup from registry
        address rollupAddress = ROLLUP_REGISTRY.getCanonicalRollup();
        IAztecStaking rollup = IAztecStaking(rollupAddress);

        // Snapshot balance before the loop
        uint256 balanceBefore = STAKING_ASSET.balanceOf(address(this));
        uint256 sumOfExitAmounts = 0;

        uint256 i = 0;
        // Loop over pending requests to claim matured withdrawals (intentional batch operation)
        while (i < _pendingUnstakeRequests.length) {
            address attester = _pendingUnstakeRequests[i];

            // Query exit.amount BEFORE finalizeWithdraw (exit is deleted after)
            AttesterView memory view_ = rollup.getAttesterView(attester);

            // Skip if exit doesn't exist (already finalized externally)
            if (!view_.exit.exists) {
                _isUnstakePending[attester] = false;
                // Remove from pending list (swap and pop)
                uint256 lastIndex = _pendingUnstakeRequests.length - 1;
                if (i != lastIndex) {
                    _pendingUnstakeRequests[i] = _pendingUnstakeRequests[lastIndex];
                }
                _pendingUnstakeRequests.pop();
                continue;
            }

            uint256 exitAmount = view_.exit.amount;

            // Try to finalize this withdrawal
            // solhint-disable-next-line no-empty-blocks
            try rollup.finalizeWithdraw(attester) {
                sumOfExitAmounts += exitAmount;
                _isUnstakePending[attester] = false;
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

        // Compute total claimed after the loop
        uint256 balanceAfter = STAKING_ASSET.balanceOf(address(this));
        claimed = balanceAfter - balanceBefore;

        // Validate consistency: sumOfExitAmounts should match actual token transfer
        // This ensures all exit amounts were correctly accounted for
        if (sumOfExitAmounts != claimed) {
            revert StakingManager__ClaimAmountMismatch();
        }

        if (claimed > 0) {
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
