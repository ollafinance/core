// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";

import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { RolesLib } from "src/shared/RolesLib.sol";
import { IAztecRollup } from "src/staking/interfaces/IAztecRollup.sol";
import { IAztecRollupRegistry } from "src/staking/interfaces/IAztecRollupRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { AttesterView, Status, Timestamp } from "src/staking/libraries/AztecTypes.sol";
import { Queue, QueueLib } from "src/staking/libraries/QueueLib.sol";

/// @title StakingManager
/// @notice Manages staking delegation, attester keys, and reward harvesting.
/// @author Olla Core contributors
contract StakingManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuard, IStakingManager {
    using SafeERC20 for IERC20;
    using QueueLib for Queue;

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for staking provider admin to manage keys.
    bytes32 public constant STAKING_PROVIDER_ADMIN_ROLE = RolesLib.STAKING_PROVIDER_ADMIN_ROLE;

    /*//////////////////////////////////////////////////////////////
                                   STATE
    //////////////////////////////////////////////////////////////*/

    // Storage layout (v1): do not reorder or remove variables.
    // - Only append new variables above `__gap` and reduce its length accordingly.
    // - This contract is used behind an ERC1967/UUPS proxy; layout must remain upgrade-safe.

    /// @notice The staking asset (AZTEC token).
    IERC20 public stakingAsset;

    /// @notice The Aztec rollup registry contract.
    IAztecRollupRegistry public rollupRegistry;

    /// @notice The rewards vault contract.
    address public rewardsVault;

    /// @notice The OllaCore contract address.
    address public core;

    /// @notice Address authorized to perform upgrades.
    address public governance;

    /// @dev Provider configuration.
    ProviderConfig private _provider;

    /// @dev FIFO queue of attester keys.
    Queue private _providerQueue;

    /// @dev List of activated attester stakes.
    AttesterStake[] private _activatedAttesters;

    // Store what the attester has originally staked, i.e. activation threshold (as this is a changeable)
    /// @dev Mapping from attester to index in _activatedAttesters.
    mapping(address attester => uint256 index) private _attesterIndex;

    /// @dev Mapping to check if an attester is activated.
    mapping(address attester => bool isActivated) private _isActivatedAttester;

    /// @dev List of pending unstake attester stakes.
    AttesterStake[] private _pendingUnstakeRequests;

    /// @dev Mapping to check if an attester has a pending unstake.
    mapping(address attester => bool isPending) private _isUnstakePending;

    /// @dev Cumulative slashing delta tracked across rollup snapshots.
    uint256 private _cumulativeSlashingDelta;

    /// @notice Storage gap for future upgrades.
    // slither-disable-next-line unused-state
    uint256[48] private __gap;

    /*//////////////////////////////////////////////////////////////
                                   ERRORS
     //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a caller is not authorized governance.
    error StakingManager__UnauthorizedGovernance(address caller);

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
     //////////////////////////////////////////////////////////////*/

    modifier onlyCore() {
        if (msg.sender != core) {
            revert StakingManager__UnauthorizedCore(msg.sender);
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

    /// @inheritdoc IStakingManager
    function initialize(
        IERC20 stakingAsset_,
        address rollupRegistry_,
        address rewardsVault_,
        address core_,
        address providerAdmin_,
        address providerRewardsRecipient_,
        address defaultAdmin_
    ) external override initializer {
        if (address(stakingAsset_) == address(0)) {
            revert StakingManager__ZeroAddress("stakingAsset");
        }
        if (rollupRegistry_ == address(0)) {
            revert StakingManager__ZeroAddress("rollupRegistry");
        }
        if (rewardsVault_ == address(0)) {
            revert StakingManager__ZeroAddress("rewardsVault");
        }
        if (core_ == address(0)) {
            revert StakingManager__ZeroAddress("core");
        }
        if (providerAdmin_ == address(0)) {
            revert StakingManager__ZeroAddress("providerAdmin");
        }
        if (providerRewardsRecipient_ == address(0)) {
            revert StakingManager__ZeroAddress("providerRewardsRecipient");
        }
        if (defaultAdmin_ == address(0)) {
            revert StakingManager__ZeroAddress("defaultAdmin");
        }

        __AccessControl_init();

        stakingAsset = stakingAsset_;
        rollupRegistry = IAztecRollupRegistry(rollupRegistry_);
        rewardsVault = rewardsVault_;
        core = core_;
        governance = defaultAdmin_;

        _provider = ProviderConfig({ admin: providerAdmin_, rewardsRecipient: providerRewardsRecipient_ });

        _providerQueue.init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin_);
        _grantRole(STAKING_PROVIDER_ADMIN_ROLE, providerAdmin_);

        emit ProviderSet(providerAdmin_, providerRewardsRecipient_);
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function stake(uint256 amount) external override onlyCore nonReentrant {
        if (amount == 0) revert StakingManager__ZeroAmount();
        _stake(amount);
    }

    /// @inheritdoc IStakingManager
    function unstake(uint256 amount) external override onlyCore nonReentrant {
        if (amount == 0) revert StakingManager__ZeroAmount();
        _unstake(amount);
    }

    // slither-disable-start calls-loop
    // Array length cannot be cached because elements are removed during iteration
    // slither-disable-start pess-multiple-storage-read,cache-array-length
    /// @notice Syncs activated attesters with the rollup exit state.
    /// @dev Moves exited attesters into the pending unstake queue.
    function cleanActivatedAttesters() external override onlyCore nonReentrant {
        // TODO: research if we can assume moving with rollup is safe
        address rollupAddress = rollupRegistry.getCanonicalRollup();
        IAztecRollup rollup = IAztecRollup(rollupAddress);

        uint256 i = 0;
        while (i < _activatedAttesters.length) {
            AttesterStake storage attesterStake = _activatedAttesters[i];
            address attester = attesterStake.attester;
            AttesterView memory view_ = rollup.getAttesterView(attester);
            if (view_.exit.exists) {
                uint256 stakedAmount = _removeActivatedAttester(attester);
                _pendingUnstakeRequests.push(AttesterStake({ attester: attester, stakedAmount: stakedAmount }));
                _isUnstakePending[attester] = true;
            } else {
                ++i;
            }
        }
    }

    // slither-disable-end pess-multiple-storage-read,cache-array-length
    // slither-disable-end calls-loop

    /// @inheritdoc IStakingManager
    function getUnstakedFunds() external override onlyCore nonReentrant returns (uint256 received) {
        return _claimUnstakedFunds();
    }

    /// @inheritdoc IStakingManager
    function harvestRewards() external override onlyCore nonReentrant returns (uint256 harvested) {
        (, IAztecRollup rollup) = _getRollup();
        harvested = rollup.claimSequencerRewards(rewardsVault);
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
            revert StakingManager__ZeroAddress("rewardsRecipient");
        }
        _provider.rewardsRecipient = rewardsRecipient;
        emit ProviderSet(_provider.admin, rewardsRecipient);
    }

    /// @notice Returns the cumulative slashing delta from the rollup.
    /// @return slashingDelta The cumulative slashing delta.
    function getSlashingDelta() external override onlyCore returns (uint256 slashingDelta) {
        (, IAztecRollup rollup) = _getRollup();
        uint256 currentSlashingDelta = _computeSlashed(rollup);
        if (currentSlashingDelta > _cumulativeSlashingDelta) {
            _cumulativeSlashingDelta = currentSlashingDelta;
        }
        return _cumulativeSlashingDelta;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal helper to get the claimable rewards.
    /// @dev Internal helper to get the claimable rewards.
    /// @return claimableRewards The total rewards claimable to rewards recipient.
    function getClaimableRewards() external view override onlyCore returns (uint256 claimableRewards) {
        (, IAztecRollup rollup) = _getRollup();
        return rollup.getSequencerRewards(address(rewardsVault));
    }

    // slither-disable-start calls-loop,timestamp
    /// @notice Returns aggregated staking state from the rollup.
    /// @return state The aggregated staking state.
    function getStakingState() external view override returns (StakingState memory state) {
        // TODO: research if we can assume moving with rollup is safe
        (, IAztecRollup rollup) = _getRollup();

        state = _getActivatedAttestersStakingState(rollup);
        StakingState memory pendingState = _getPendingUnstakeRequestsStakingState(rollup);

        state.pendingUnstakeAmount += pendingState.pendingUnstakeAmount;
        state.withdrawableAmount += pendingState.withdrawableAmount;

        return state;
    }

    // slither-disable-end calls-loop,timestamp

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256 stakedTotal) {
        // TODO: research if we can assume moving with rollup is safe
        (, IAztecRollup rollup) = _getRollup();
        stakedTotal = _computeStaked(rollup);
        return stakedTotal;
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
    // Reentrancy safe: caller (stake) has nonReentrant modifier
    //   also the called contract is trusted Aztec protocol contract
    // slither-disable-start reentrancy-no-eth
    // slither-disable-next-line ordering
    function _stake(uint256 amount) internal {
        uint256 availableKeys = _providerQueue.length();
        if (availableKeys == 0) {
            revert StakingManager__InsufficientKeys();
        }
        (address rollupAddress, IAztecRollup rollup) = _getRollup();
        uint256 activationThreshold = rollup.getActivationThreshold();
        uint256 attestersToStakeTo = _calculateAttestersToStake(amount, activationThreshold, availableKeys);
        uint256 actualStakeAmount = attestersToStakeTo * activationThreshold;

        _transferAndApproveStake(rollupAddress, actualStakeAmount);
        _stakeAttesters(rollup, attestersToStakeTo, activationThreshold);
        stakingAsset.forceApprove(rollupAddress, 0);
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
    // Reentrancy safe: caller (unstake) has nonReentrant modifier
    //   also the called contract is trusted Aztec protocol contract
    // slither-disable-start reentrancy-no-eth
    function _unstake(uint256 amount) internal {
        (, IAztecRollup rollup) = _getRollup();
        uint256 totalUnstakedAmount = _initiateUnstakeRequests(rollup, amount);
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
    // Reentrancy safe: caller (claimUnstakedFunds) has nonReentrant modifier
    //   also the called contract is trusted Aztec protocol contract
    // slither-disable-start reentrancy-no-eth
    function _claimUnstakedFunds() internal returns (uint256 claimed) {
        (, IAztecRollup rollup) = _getRollup();

        uint256 balanceBefore = stakingAsset.balanceOf(address(this));
        uint256 sumOfExitAmounts = _finalizePendingUnstakes(rollup);
        claimed = _finalizeClaim(balanceBefore, sumOfExitAmounts);
        return claimed;
    }

    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    /// @notice Adds an attester to the activated attesters list.
    /// @param attester The attester address.
    /// @param stakedAmount The amount staked for this attester.
    function _addActivatedAttester(address attester, uint256 stakedAmount) internal {
        if (!_isActivatedAttester[attester]) {
            _attesterIndex[attester] = _activatedAttesters.length;
            _activatedAttesters.push(AttesterStake({ attester: attester, stakedAmount: stakedAmount }));
            _isActivatedAttester[attester] = true;
        }
    }

    // TODO: see if we can optimize this further
    // slither-disable-start costly-loop
    // slither-disable-start pess-multiple-storage-read
    /// @notice Removes an attester from the activated attesters list.
    /// @param attester The attester address.
    /// @return stakedAmount The amount that was staked for this attester.
    function _removeActivatedAttester(address attester) internal returns (uint256 stakedAmount) {
        if (_isActivatedAttester[attester]) {
            uint256 index = _attesterIndex[attester];
            uint256 lastIndex = _activatedAttesters.length - 1;
            stakedAmount = _activatedAttesters[index].stakedAmount;

            if (index != lastIndex) {
                AttesterStake storage lastStake = _activatedAttesters[lastIndex];
                _activatedAttesters[index] = lastStake;
                _attesterIndex[lastStake.attester] = index;
            }

            _activatedAttesters.pop();
            delete _attesterIndex[attester];
            _isActivatedAttester[attester] = false;
        }
        return stakedAmount;
    }

    // slither-disable-end costly-loop
    // slither-disable-end pess-multiple-storage-read

    /// @notice Transfers assets from core and approves the rollup.
    /// @param rollupAddress The rollup address to approve.
    /// @param actualStakeAmount The amount to transfer and approve.
    function _transferAndApproveStake(address rollupAddress, uint256 actualStakeAmount) internal {
        // Note: `core` is a trusted address set during initialization, not arbitrary.
        // slither-disable-next-line arbitrary-send-erc20,pess-nft-approve-warning
        stakingAsset.safeTransferFrom(core, address(this), actualStakeAmount);
        stakingAsset.forceApprove(rollupAddress, actualStakeAmount);
    }

    /// @notice Stakes a batch of attesters on the rollup.
    /// @dev Reentrancy protection provided by external caller (stake).
    /// @param rollup The rollup staking interface.
    /// @param attestersToStakeTo The number of attesters to stake.
    /// @param activationThreshold The stake amount per attester.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    function _stakeAttesters(IAztecRollup rollup, uint256 attestersToStakeTo, uint256 activationThreshold) internal {
        for (uint256 i; i < attestersToStakeTo; ++i) {
            KeyStore memory keyStore = _providerQueue.dequeue();
            _addActivatedAttester(keyStore.attester, activationThreshold);
            emit StakedWithProvider(keyStore.attester, activationThreshold);
            // External call is safe:
            // - Caller has nonReentrant modifier
            // - State fully updated before call (CEI pattern)
            // slither-disable-next-line reentrancy-no-eth
            rollup.deposit(
                keyStore.attester,
                address(this),
                keyStore.publicKeyG1,
                keyStore.publicKeyG2,
                keyStore.proofOfPossession,
                true
            );
        }
    }

    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    /// @notice Initiates unstake requests for activated attesters.
    /// @dev External calls inside loop are safe:
    ///      - rollup is a trusted Aztec contract
    ///      - attesters are permissioned
    ///      - failure should revert entire unstake operation
    /// @param rollup The rollup staking interface.
    /// @param amount The amount to unstake.
    /// @return totalUnstakedAmount The total amount initiated for unstake.
    // Array length cannot be cached because elements are removed during iteration
    // slither-disable-next-line pess-multiple-storage-read,cache-array-length
    function _initiateUnstakeRequests(IAztecRollup rollup, uint256 amount)
        internal
        onlyCore
        returns (uint256 totalUnstakedAmount)
    {
        uint256 i = 0;
        while (i < _activatedAttesters.length) {
            AttesterStake storage attesterStake = _activatedAttesters[i];
            (bool incrementIndex, uint256 exitAmount) =
                _processUnstakeAttester(rollup, attesterStake.attester, attesterStake.stakedAmount);
            totalUnstakedAmount += exitAmount;
            if (totalUnstakedAmount > amount - 1) {
                break;
            }
            if (incrementIndex) {
                ++i;
            }
        }
        return totalUnstakedAmount;
    }

    /// @notice Processes a single attester unstake attempt.
    /// @dev External calls inside a loop are intentional and safe:
    ///      - `rollup` is a trusted Aztec protocol contract
    ///      - Attesters are permissioned and managed by the provider
    ///      - Function is only reachable via core-gated entrypoints with nonReentrant
    ///      - State updates after external call are benign (internal bookkeeping only)
    ///      - Failure is expected to revert the entire unstake operation
    /// @param rollup The rollup staking interface.
    /// @param attester The attester address to process.
    /// @param stakedAmount The amount originally staked for this attester.
    /// @return incrementIndex Whether the caller should advance the index.
    /// @return exitAmount The unstake amount initiated for the attester.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    function _processUnstakeAttester(IAztecRollup rollup, address attester, uint256 stakedAmount)
        internal
        returns (bool incrementIndex, uint256 exitAmount)
    {
        AttesterView memory view_ = rollup.getAttesterView(attester);
        exitAmount = view_.effectiveBalance;

        bool isInitiated = rollup.initiateWithdraw(attester, address(this));
        if (!isInitiated) {
            if (view_.exit.exists) {
                _moveToPendingUnstake(attester, stakedAmount, false);
                return (true, 0);
            }
            revert StakingManager__UnstakeFailed(attester);
        }

        _moveToPendingUnstake(attester, stakedAmount, true);
        emit UnstakeInitiated(attester, exitAmount);
        return (false, exitAmount);
    }

    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    /// @notice Moves an attester from activated to pending unstake tracking.
    /// @param attester The attester address.
    /// @param stakedAmount The amount originally staked for this attester.
    /// @param markPending Whether to mark the attester as pending in the mapping.
    function _moveToPendingUnstake(address attester, uint256 stakedAmount, bool markPending) internal {
        _removeActivatedAttester(attester);
        _pendingUnstakeRequests.push(AttesterStake({ attester: attester, stakedAmount: stakedAmount }));
        if (markPending) {
            _isUnstakePending[attester] = true;
        }
    }

    /// @notice Finalizes pending unstake requests that are exitable.
    /// @dev Reentrancy protection provided by external caller (getUnstakedFunds).
    /// @param rollup The rollup staking interface.
    /// @return sumOfExitAmounts The total amount finalized.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    // Array length cannot be cached because elements are removed during iteration
    // slither-disable-start pess-multiple-storage-read,cache-array-length
    function _finalizePendingUnstakes(IAztecRollup rollup) internal returns (uint256 sumOfExitAmounts) {
        uint256 i = 0;
        while (i < _pendingUnstakeRequests.length) {
            AttesterStake storage attesterStake = _pendingUnstakeRequests[i];
            address attester = attesterStake.attester;
            AttesterView memory view_ = rollup.getAttesterView(attester);
            if (!view_.exit.exists) {
                _isUnstakePending[attester] = false;
                _removePendingUnstakeAtIndex(i);
                continue;
            }

            // slither-disable-next-line timestamp
            // Timestamp used only to gate exit readiness from the rollup state.
            // slither-disable-next-line timestamp
            if (Timestamp.unwrap(view_.exit.exitableAt) > block.timestamp) {
                ++i;
                continue;
            }
            sumOfExitAmounts += view_.exit.amount;
            _isUnstakePending[attester] = false;
            _removePendingUnstakeAtIndex(i);
            emit UnstakeFinalized(attester, view_.exit.amount);
            // External call is safe:
            // - Caller has nonReentrant modifier
            // - State fully updated before call (CEI pattern)
            // slither-disable-next-line reentrancy-no-eth
            rollup.finalizeWithdraw(attester);
        }
        return sumOfExitAmounts;
    }

    // slither-disable-end pess-multiple-storage-read,cache-array-length
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    // TODO: see if we can optimize this further
    // slither-disable-start pess-multiple-storage-read
    /// @notice Removes a pending unstake request at the given index.
    /// @param index The index to remove.
    function _removePendingUnstakeAtIndex(uint256 index) internal {
        uint256 lastIndex = _pendingUnstakeRequests.length - 1;
        if (index != lastIndex) {
            _pendingUnstakeRequests[index] = _pendingUnstakeRequests[lastIndex];
        }
        _pendingUnstakeRequests.pop();
    }

    // slither-disable-end pess-multiple-storage-read

    /// @notice Finalizes a claim by validating and transferring unstaked funds.
    /// @param balanceBefore The token balance before finalization.
    /// @param sumOfExitAmounts The sum of finalized exit amounts.
    /// @return claimed The amount claimed and transferred.
    function _finalizeClaim(uint256 balanceBefore, uint256 sumOfExitAmounts) internal returns (uint256 claimed) {
        uint256 balanceAfter = stakingAsset.balanceOf(address(this));
        claimed = balanceAfter - balanceBefore;
        if (sumOfExitAmounts != claimed) {
            revert StakingManager__ClaimAmountMismatch();
        }

        if (claimed > 0) {
            stakingAsset.safeTransfer(core, claimed);
            emit UnstakedFundsClaimed(claimed);
        }
        return claimed;
    }

    /// @notice Returns the canonical rollup address and interface.
    /// @return rollupAddress The canonical rollup address.
    /// @return rollup The rollup staking interface.
    function _getRollup() internal view returns (address rollupAddress, IAztecRollup rollup) {
        rollupAddress = rollupRegistry.getCanonicalRollup();
        rollup = IAztecRollup(rollupAddress);
        return (rollupAddress, rollup);
    }

    // slither-disable-start calls-loop,timestamp,pess-multiple-storage-read
    function _getActivatedAttestersStakingState(IAztecRollup rollup) internal view returns (StakingState memory state) {
        uint256 activatedLength = _activatedAttesters.length;
        for (uint256 i; i < activatedLength; ++i) {
            AttesterStake storage attesterStake = _activatedAttesters[i];
            AttesterView memory view_ = rollup.getAttesterView(attesterStake.attester);

            if (view_.status == Status.VALIDATING && view_.effectiveBalance > 0) {
                state.stakedAmount += view_.effectiveBalance;
            }

            // Handle attesters that may have been externally exited e.g.
            //   ZOMBIE - attester has been slashed too much to continue validating
            //   EXITING - provider has initiated an exit outside of StakingManager
            if (view_.exit.exists) {
                // Timestamp used only to gate exit readiness from the rollup state.
                // slither-disable-next-line timestamp
                if (Timestamp.unwrap(view_.exit.exitableAt) > block.timestamp) {
                    state.pendingUnstakeAmount += view_.exit.amount;
                } else {
                    state.withdrawableAmount += view_.exit.amount;
                }
            }
        }
        return state;
    }

    // slither-disable-end calls-loop,timestamp,pess-multiple-storage-read

    // slither-disable-start calls-loop,timestamp,pess-multiple-storage-read
    function _getPendingUnstakeRequestsStakingState(IAztecRollup rollup)
        internal
        view
        returns (StakingState memory state)
    {
        uint256 pendingLength = _pendingUnstakeRequests.length;
        for (uint256 i; i < pendingLength; ++i) {
            AttesterStake storage attesterStake = _pendingUnstakeRequests[i];
            AttesterView memory view_ = rollup.getAttesterView(attesterStake.attester);

            if (view_.exit.exists) {
                // Timestamp used only to gate exit readiness from the rollup state.
                // slither-disable-next-line timestamp
                if (Timestamp.unwrap(view_.exit.exitableAt) > block.timestamp) {
                    state.pendingUnstakeAmount += view_.exit.amount;
                } else {
                    state.withdrawableAmount += view_.exit.amount;
                }
            }
        }
        return state;
    }

    // slither-disable-end calls-loop,timestamp,pess-multiple-storage-read

    function _computeStaked(IAztecRollup rollup) internal view returns (uint256 stakedTotal) {
        (stakedTotal,) = _accumulateAttestersDelta(rollup, _activatedAttesters, 0, 0);
        (stakedTotal,) = _accumulateAttestersDelta(rollup, _pendingUnstakeRequests, stakedTotal, 0);
        return stakedTotal;
    }

    function _computeSlashed(IAztecRollup rollup) internal view returns (uint256 slashingDelta) {
        (, slashingDelta) = _accumulateAttestersDelta(rollup, _activatedAttesters, 0, 0);
        (, slashingDelta) = _accumulateAttestersDelta(rollup, _pendingUnstakeRequests, 0, slashingDelta);
        return slashingDelta;
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != governance) {
            revert StakingManager__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert StakingManager__ZeroAddress("newImplementation");
        }
    }

    // Rollup is trusted and loop bounded by attester set size.
    // slither-disable-next-line calls-loop
    function _accumulateAttestersDelta(
        IAztecRollup rollup,
        AttesterStake[] storage attesters,
        uint256 stakedTotal,
        uint256 slashingDelta
    ) internal view returns (uint256 updatedTotalStaked, uint256 updatedSlashingDelta) {
        uint256 length = attesters.length;
        for (uint256 i; i < length; ++i) {
            AttesterStake storage attesterStake = attesters[i];
            AttesterView memory view_ = rollup.getAttesterView(attesterStake.attester);
            (bool eligible, uint256 remaining) = _remainingStake(view_);
            if (!eligible) {
                continue;
            }
            stakedTotal += attesterStake.stakedAmount;
            if (attesterStake.stakedAmount > remaining) {
                slashingDelta += attesterStake.stakedAmount - remaining;
            }
        }
        return (stakedTotal, slashingDelta);
    }

    /// @notice Calculates the attester count to stake to, bounded by available keys.
    /// @param amount The stake amount requested.
    /// @param activationThreshold The stake amount per attester.
    /// @param availableKeys The number of keys available in the queue.
    /// @return attestersToStakeTo The number of attesters to stake.
    function _calculateAttestersToStake(uint256 amount, uint256 activationThreshold, uint256 availableKeys)
        internal
        pure
        returns (uint256 attestersToStakeTo)
    {
        attestersToStakeTo = amount / activationThreshold;
        if (attestersToStakeTo == 0) {
            revert StakingManager__InsufficientAmount();
        }
        if (attestersToStakeTo > availableKeys) {
            attestersToStakeTo = availableKeys;
        }
        return attestersToStakeTo;
    }

    function _remainingStake(AttesterView memory view_) internal pure returns (bool eligible, uint256 remaining) {
        if (view_.effectiveBalance > 0) {
            return (true, view_.effectiveBalance);
        }
        if (view_.exit.exists) {
            return (true, view_.exit.amount);
        }
        return (false, 0);
    }
}
