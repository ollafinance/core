// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@oz/utils/math/SafeCast.sol";
import { ReentrancyGuardTransient } from "@oz/utils/ReentrancyGuardTransient.sol";
import { EnumerableSet } from "@oz/utils/structs/EnumerableSet.sol";
import { IAztecGovernance } from "src/staking/interfaces/IAztecGovernance.sol";
import { IAztecRollup } from "src/staking/interfaces/IAztecRollup.sol";
import { IAztecRollupRegistry } from "src/staking/interfaces/IAztecRollupRegistry.sol";
import { IStakingManager, IStakingManagerRewardRollupAdmin } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { AttesterView, Status, Timestamp } from "src/staking/libraries/AztecTypes.sol";

// solhint-disable max-states-count
/// @title StakingManager
/// @notice Manages staking delegation, attester keys, and reward harvesting.
/// @dev Uses mapping-based attester registry with an EnumerableSet for active attesters
///      and an incremental running state accumulator.
/// @author Olla Core contributors
contract StakingManager is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    IStakingManager,
    IStakingManagerRewardRollupAdmin
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum allowed gas threshold (30 million).
    uint256 private constant _MAX_GAS_THRESHOLD = 30_000_000;

    /// @notice Event field value for aggregate stakedAmount underflow clamps.
    bytes32 private constant _AGGREGATE_FIELD_STAKED_AMOUNT = keccak256("stakedAmount");

    /// @notice Event field value for aggregate pendingUnstakeAmount underflow clamps.
    bytes32 private constant _AGGREGATE_FIELD_PENDING_UNSTAKE_AMOUNT = keccak256("pendingUnstakeAmount");

    /*//////////////////////////////////////////////////////////////
                                    STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The staking asset (AZTEC token).
    IERC20 public stakingAsset;

    /// @notice The Aztec rollup registry contract.
    IAztecRollupRegistry public rollupRegistry;

    /// @notice The rewards vault contract.
    address public rewardsAccumulator;

    /// @notice The OllaCore contract address.
    address public core;

    /// @notice The StakingProviderRegistry contract.
    IStakingProviderRegistry public stakingProviderRegistry;

    /// @dev Tracks finalized but unclaimed exit amounts for correct accounting.
    uint256 private _pendingClaimAmount;

    /// @dev Count of active attesters in the registry.
    uint64 private _activeCount;

    /// @dev Count of exiting attesters in the registry.
    uint64 private _exitingCount;

    /// @dev Total number of registered attesters in the mapping.
    uint64 private _attesterCount;

    /// @dev Gas threshold for bounded staking batch work.
    uint32 private _gasThreshold;

    /// @notice Governance contract authorized to perform UUPS upgrades.
    address public governanceUpgradeAuthority;

    /// @dev Mapping-based attester registry. O(1) access by address.
    mapping(address attester => AttesterInfo info) private _attesterMap;

    /// @dev Incrementally maintained aggregate staking state accumulator.
    StakingState private _aggregateState;

    /// @dev Enumerable set of active attester addresses for internal iteration (unstake).
    EnumerableSet.AddressSet private _activeAttesterSet;

    /// @dev Tracks purged failed-entry refunds that can be swept without double-counting principal.
    uint256 private _pendingRefundAmount;

    /// @dev Rollups still relevant for sequencer reward reads and harvesting.
    address[] private _rewardRollups;

    /// @dev Membership guard for _rewardRollups.
    mapping(address rollup => bool tracked) private _isRewardRollup;

    /// @notice Storage gap for future upgrades.
    /// @dev When adding new state variables, append them above this gap and reduce its length
    ///      by the number of slots consumed. Target: 50 gap slots across all upgradeable contracts.
    // slither-disable-next-line unused-state
    uint256[45] private __gap;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the gas threshold is updated.
    /// @param oldValue The previous gas threshold.
    /// @param newValue The new gas threshold.
    event GasThresholdUpdated(uint256 indexed oldValue, uint256 indexed newValue);

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
        address rewardsAccumulator_,
        address core_,
        address stakingProviderRegistry_,
        address defaultAdmin_
    ) external override initializer {
        if (address(stakingAsset_) == address(0)) {
            revert StakingManager__ZeroAddress("stakingAsset");
        }
        if (rollupRegistry_ == address(0)) {
            revert StakingManager__ZeroAddress("rollupRegistry");
        }
        if (rewardsAccumulator_ == address(0)) {
            revert StakingManager__ZeroAddress("rewardsAccumulator");
        }
        if (core_ == address(0)) {
            revert StakingManager__ZeroAddress("core");
        }
        if (stakingProviderRegistry_ == address(0)) {
            revert StakingManager__ZeroAddress("stakingProviderRegistry");
        }
        if (defaultAdmin_ == address(0)) {
            revert StakingManager__ZeroAddress("defaultAdmin");
        }

        __AccessControl_init();

        stakingAsset = stakingAsset_;
        rollupRegistry = IAztecRollupRegistry(rollupRegistry_);
        rewardsAccumulator = rewardsAccumulator_;
        core = core_;
        stakingProviderRegistry = IStakingProviderRegistry(stakingProviderRegistry_);
        _gasThreshold = 50_000;
        governanceUpgradeAuthority = defaultAdmin_;

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin_);

        _trackRewardRollup(rollupRegistry.getCanonicalRollup());
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function stake(uint256 amount) external override onlyCore nonReentrant returns (uint256 stakedAmount) {
        if (amount == 0) revert StakingManager__ZeroAmount();
        stakedAmount = _stake(amount);
        return stakedAmount;
    }

    /// @notice Sets the gas threshold used for bounded staking batch work.
    /// @param threshold The gas threshold to enforce.
    function setGasThreshold(uint256 threshold) external override onlyCore {
        if (threshold == 0) revert StakingManager__ZeroAmount();
        if (threshold > _MAX_GAS_THRESHOLD) revert StakingManager__InvalidParameter();
        uint256 previousThreshold = _gasThreshold;
        _gasThreshold = SafeCast.toUint32(threshold);
        emit GasThresholdUpdated(previousThreshold, threshold);
    }

    // slither-disable-start calls-loop
    // slither-disable-start costly-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-no-eth
    // slither-disable-start pess-multiple-storage-read
    /// @inheritdoc IStakingManager
    function unstake(uint256 amount) external override onlyCore nonReentrant returns (uint256 unstakedAmount) {
        if (amount == 0) revert StakingManager__ZeroAmount();
        (, IAztecRollup rollup) = _getRollup();

        uint256 length = _activeAttesterSet.length();
        if (length == 0 || _activeCount == 0) {
            return 0;
        }

        // Iterate active attesters from the end to avoid index shifting on removal.
        for (uint256 i = length; i > 0;) {
            --i;
            if (unstakedAmount >= amount) break;
            if (gasleft() < _gasThreshold) break;

            address attester = _activeAttesterSet.at(i);
            AttesterInfo storage info = _attesterMap[attester];
            if (info.status != InternalAttesterStatus.Active) continue;

            uint256 exitAmount = _processUnstakeAttester(rollup, attester, info);
            unstakedAmount += exitAmount;
        }

        return unstakedAmount;
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end costly-loop
    // slither-disable-end calls-loop

    /// @inheritdoc IStakingManager
    function getUnstakedFunds() external override onlyCore nonReentrant returns (uint256 received, uint256 exitAmount) {
        exitAmount = _pendingClaimAmount;
        _pendingClaimAmount = 0;
        uint256 refundAmount = _pendingRefundAmount;
        _pendingRefundAmount = 0;

        uint256 balance = stakingAsset.balanceOf(address(this));
        uint256 accountedAmount = exitAmount + refundAmount;
        uint256 transferAmount = balance < accountedAmount ? balance : accountedAmount;

        if (transferAmount > 0) {
            stakingAsset.safeTransfer(core, transferAmount);
            emit UnstakedFundsClaimed(transferAmount);
        }
        received = transferAmount;
        return (received, exitAmount);
    }

    // slither-disable-start calls-loop
    // slither-disable-start costly-loop
    // slither-disable-start reentrancy-no-eth
    /// @inheritdoc IStakingManager
    function harvestRewards() external override onlyCore nonReentrant returns (uint256 harvested) {
        address canonicalRollup = _ensureCanonicalRewardRollup();
        bool claimSucceeded = false;
        uint256 length = _rewardRollups.length;

        for (uint256 i; i < length;) {
            address rollupAddress = _rewardRollups[i];
            bool removeRollup = false;

            try IAztecRollup(rollupAddress).claimSequencerRewards(rewardsAccumulator) returns (uint256 claimed) {
                claimSucceeded = true;
                harvested += claimed;
                emit RewardsHarvestedFromRollup(rollupAddress, claimed);
                uint256 remaining = IAztecRollup(rollupAddress).getSequencerRewards(address(rewardsAccumulator));
                removeRollup = rollupAddress != canonicalRollup && remaining == 0;
            } catch (bytes memory reason) {
                emit RewardsHarvestFailed(reason);
            }

            if (removeRollup) {
                _removeRewardRollupAt(i);
                --length;
            } else {
                ++i;
            }
        }

        if (claimSucceeded) {
            emit RewardsHarvested(harvested);
        }
        return harvested;
    }

    /// @inheritdoc IStakingManagerRewardRollupAdmin
    function removeDrainedRewardRollup(address rollup) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isRewardRollup[rollup]) {
            revert StakingManager__RewardRollupNotTracked(rollup);
        }
        if (rollup == rollupRegistry.getCanonicalRollup()) {
            revert StakingManager__CannotRemoveCanonicalRewardRollup(rollup);
        }

        uint256 rewards = IAztecRollup(rollup).getSequencerRewards(address(rewardsAccumulator));
        if (rewards != 0) {
            revert StakingManager__RewardRollupHasPendingRewards(rollup, rewards);
        }

        _removeRewardRollup(rollup);
    }

    // slither-disable-end reentrancy-no-eth
    // slither-disable-end costly-loop
    // slither-disable-end calls-loop

    /*//////////////////////////////////////////////////////////////
                        PERMISSIONLESS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // slither-disable-start calls-loop
    // slither-disable-start costly-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-no-eth
    /// @inheritdoc IStakingManager
    function refreshAttesterState(address[] calldata attesters) external override nonReentrant {
        (, IAztecRollup rollup) = _getRollup();
        for (uint256 i = 0; i < attesters.length; ++i) {
            _refreshSingleAttester(rollup, attesters[i]);
        }
    }

    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end costly-loop
    // slither-disable-end calls-loop

    // slither-disable-start pess-multiple-storage-read
    /// @inheritdoc IStakingManager
    function purgeFailedQueueEntry(address attester) external override nonReentrant {
        AttesterInfo storage info = _attesterMap[attester];

        // Must be an attester we know about and marked Queued (deposited but not yet activated)
        if (info.attester == address(0) || info.status != InternalAttesterStatus.Queued) {
            revert StakingManager__NotFailedQueueEntry(attester);
        }

        // Query the rollup where the deposit was queued. Canonical may have changed before flush.
        address queueRollupAddress = info.queueRollup;
        IAztecRollup rollup = IAztecRollup(queueRollupAddress);
        AttesterView memory view_ = rollup.getAttesterView(attester);
        if (view_.status != Status.NONE || view_.exit.exists || view_.effectiveBalance > 0) {
            revert StakingManager__NotFailedQueueEntry(attester);
        }

        (address canonicalRollupAddress, IAztecRollup canonicalRollup) = _getRollup();
        if (canonicalRollupAddress != queueRollupAddress) {
            AttesterView memory canonicalView = canonicalRollup.getAttesterView(attester);
            if (canonicalView.status != Status.NONE || canonicalView.exit.exists || canonicalView.effectiveBalance > 0)
            {
                revert StakingManager__NotFailedQueueEntry(attester);
            }
        }

        // Verify the attester is NOT still in the rollup's entry queue (waiting for flush).
        // If found in the queue, the deposit hasn't been processed yet — not a failed entry.
        uint256 queueLen = rollup.getEntryQueueLength();
        for (uint256 i; i < queueLen; ++i) {
            // slither-disable-next-line calls-loop
            if (rollup.getEntryQueueAt(i).attester == attester) {
                revert StakingManager__NotFailedQueueEntry(attester);
            }
        }

        // Correct the accounting: reclassify cached stake from queued principal to sweepable refund.
        uint256 cachedStake = info.stakedAmount;
        _removeStakedAmount(attester, cachedStake);
        _pendingRefundAmount += cachedStake;

        // Transition to Exiting then remove (reuses existing cleanup path)
        _setAttesterStatus(attester, info, InternalAttesterStatus.Exiting);
        _removeAttester(attester);

        emit FailedQueueEntryPurged(attester, cachedStake);
    }

    // slither-disable-end pess-multiple-storage-read

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the cached slashing delta.
    /// @return slashingDelta The cached slashing delta.
    function getSlashingDelta() external view override onlyCore returns (uint256 slashingDelta) {
        return _aggregateState.slashingDelta;
    }

    /// @notice Internal helper to get the claimable rewards.
    /// @dev Internal helper to get the claimable rewards.
    /// @return claimableRewards The total rewards claimable to rewards recipient.
    // slither-disable-next-line calls-loop
    function getClaimableRewards() external view override onlyCore returns (uint256 claimableRewards) {
        address canonicalRollup = rollupRegistry.getCanonicalRollup();
        bool includedCanonical = false;
        uint256 length = _rewardRollups.length;

        for (uint256 i; i < length; ++i) {
            address rollupAddress = _rewardRollups[i];
            if (rollupAddress == canonicalRollup) {
                includedCanonical = true;
            }
            uint256 unclaimedRewards = IAztecRollup(rollupAddress).getSequencerRewards(address(rewardsAccumulator));
            claimableRewards += unclaimedRewards;
        }

        if (!includedCanonical && _isExpectedRewardAsset()) {
            claimableRewards += IAztecRollup(canonicalRollup).getSequencerRewards(address(rewardsAccumulator));
        }

        return claimableRewards;
    }

    /// @inheritdoc IStakingManager
    function getStakingState() external view override returns (StakingState memory state) {
        return _aggregateState;
    }

    /// @inheritdoc IStakingManager
    function pendingUnstakes() external view override returns (uint256 pendingUnstakeAmount) {
        return _aggregateState.pendingUnstakeAmount;
    }

    /// @inheritdoc IStakingManager
    function hasFinalizedUnstakes() external view override returns (bool) {
        return _pendingClaimAmount > 0 || _pendingRefundAmount > 0;
    }

    /// @inheritdoc IStakingManager
    function claimableUnstakedFunds() external view override returns (uint256 amount) {
        return _pendingClaimAmount + _pendingRefundAmount;
    }

    /// @inheritdoc IStakingManager
    function canStake(uint256 amount) external view override returns (bool) {
        uint256 availableKeys = stakingProviderRegistry.getQueueLength();
        if (availableKeys == 0) return false;
        (, IAztecRollup rollup) = _getRollup();
        uint256 threshold = rollup.getActivationThreshold();
        return _calculateAttestersToStake(amount, threshold, availableKeys) > 0;
    }

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256 stakedTotal) {
        return _aggregateState.stakedAmount + _aggregateState.pendingUnstakeAmount + _pendingClaimAmount
            + _pendingRefundAmount;
    }

    /// @inheritdoc IStakingManager
    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return stakingProviderRegistry.getStakingProviderConfig();
    }

    /// @inheritdoc IStakingManager
    function getActivatedAttesterCount() external view override returns (uint256) {
        return _activeCount;
    }

    /// @inheritdoc IStakingManager
    function getPendingUnstakeCount() external view override returns (uint256) {
        return _exitingCount;
    }

    /// @inheritdoc IStakingManager
    function isUnstakePending(address attester) external view override returns (bool) {
        return _attesterMap[attester].status == InternalAttesterStatus.Exiting;
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
    // slither-disable-next-line ordering
    function _stake(uint256 amount) internal returns (uint256 actualStakeAmount) {
        uint256 availableKeys = stakingProviderRegistry.getQueueLength();
        if (availableKeys == 0) {
            revert StakingManager__InsufficientKeys();
        }
        (address rollupAddress, IAztecRollup rollup) = _getRollup();
        uint256 activationThresholdValue = rollup.getActivationThreshold();
        uint256 attestersToStakeTo = _calculateAttestersToStake(amount, activationThresholdValue, availableKeys);
        if (attestersToStakeTo == 0) {
            return 0;
        }
        uint256 plannedStakeAmount = attestersToStakeTo * activationThresholdValue;
        _transferAndApproveStake(rollupAddress, plannedStakeAmount);
        uint256 stakedAttesters = _stakeAttesters(rollup, attestersToStakeTo, activationThresholdValue);
        actualStakeAmount = stakedAttesters * activationThresholdValue;
        if (actualStakeAmount < plannedStakeAmount) {
            stakingAsset.safeTransfer(core, plannedStakeAmount - actualStakeAmount);
        }
        stakingAsset.forceApprove(rollupAddress, 0);
        return actualStakeAmount;
    }

    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop
    // slither-disable-end divide-before-multiply

    // slither-disable-start unused-return
    // slither-disable-start costly-loop
    // slither-disable-start pess-multiple-storage-read
    /// @notice Sets an attester status, updates counters, and maintains the active attester set.
    /// @param attester The attester address.
    /// @param info The attester info storage reference.
    /// @param newStatus The new local status.
    function _setAttesterStatus(address attester, AttesterInfo storage info, InternalAttesterStatus newStatus)
        internal
    {
        InternalAttesterStatus previousStatus = info.status;
        if (previousStatus == newStatus) {
            return;
        }
        if (previousStatus == InternalAttesterStatus.Active) {
            --_activeCount;
            _activeAttesterSet.remove(attester);
        } else if (previousStatus == InternalAttesterStatus.Exiting) {
            --_exitingCount;
        }
        if (newStatus == InternalAttesterStatus.Active) {
            ++_activeCount;
            _activeAttesterSet.add(attester);
        } else if (newStatus == InternalAttesterStatus.Exiting) {
            ++_exitingCount;
        }
        info.status = newStatus;
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end costly-loop
    // slither-disable-end unused-return

    // slither-disable-start costly-loop
    // slither-disable-start pess-multiple-storage-read
    /// @notice Removes an attester from the mapping registry and the active set.
    /// @param attester The attester address to remove.
    function _removeAttester(address attester) internal {
        AttesterInfo storage info = _attesterMap[attester];
        if (info.attester == address(0)) revert StakingManager__InvalidParameter();

        InternalAttesterStatus status = info.status;
        if (status == InternalAttesterStatus.Exiting) {
            --_exitingCount;

            /// @dev guard to prevent future code regressions, this path should never be triggerable
        } else if (status == InternalAttesterStatus.Active || status == InternalAttesterStatus.Queued) {
            revert StakingManager__RemoveAttesterFailed(attester);
        }

        delete _attesterMap[attester];
        --_attesterCount;

        emit AttesterRemoved(attester);
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end costly-loop

    // slither-disable-start pess-multiple-storage-read
    /// @notice Marks an attester as queued in the registry and updates running state.
    /// @dev The attester is deposited on the rollup but not yet activated in the GSE.
    ///      Tokens ARE on the rollup so stakedAmount is tracked, but the attester is NOT
    ///      added to _activeAttesterSet or _activeCount until promoted via refreshAttesterState.
    /// @param attester The attester address.
    /// @param stakedAmount The amount staked for this attester.
    /// @param queueRollup The rollup where the deposit was submitted.
    function _setQueued(address attester, uint256 stakedAmount, address queueRollup) internal {
        AttesterInfo storage info = _attesterMap[attester];
        if (info.attester != address(0)) {
            revert StakingManager__AttesterAlreadyActive(attester);
        }
        info.attester = attester;
        info.stakedAmount = stakedAmount;
        info.queueRollup = queueRollup;
        ++_attesterCount;
        _setAttesterStatus(attester, info, InternalAttesterStatus.Queued);
        _aggregateState.stakedAmount += stakedAmount;
    }

    /// @notice Removes principal from aggregate staked amount with saturation.
    /// @param attester The attester whose reconciliation is removing the amount.
    /// @param amount The amount to remove.
    function _removeStakedAmount(address attester, uint256 amount) internal {
        _decreaseAggregateField(attester, _AGGREGATE_FIELD_STAKED_AMOUNT, amount);
    }

    /// @notice Removes principal from aggregate pending unstake amount with saturation.
    /// @param attester The attester whose reconciliation is removing the amount.
    /// @param amount The amount to remove.
    function _removePendingUnstakeAmount(address attester, uint256 amount) internal {
        _decreaseAggregateField(attester, _AGGREGATE_FIELD_PENDING_UNSTAKE_AMOUNT, amount);
    }

    /// @notice Decreases an aggregate state field, emitting when saturation masks an underflow.
    /// @param attester The attester whose reconciliation is removing the amount.
    /// @param field The aggregate state field to decrement.
    /// @param amount The amount to remove.
    function _decreaseAggregateField(address attester, bytes32 field, uint256 amount) internal {
        if (field == _AGGREGATE_FIELD_STAKED_AMOUNT) {
            uint256 currentAmount = _aggregateState.stakedAmount;
            if (currentAmount >= amount) {
                _aggregateState.stakedAmount = currentAmount - amount;
            } else {
                emit AggregateStateUnderflowClamped(attester, field, currentAmount, amount);
                _aggregateState.stakedAmount = 0;
            }
        } else {
            uint256 currentAmount = _aggregateState.pendingUnstakeAmount;
            if (currentAmount >= amount) {
                _aggregateState.pendingUnstakeAmount = currentAmount - amount;
            } else {
                emit AggregateStateUnderflowClamped(attester, field, currentAmount, amount);
                _aggregateState.pendingUnstakeAmount = 0;
            }
        }
    }

    // slither-disable-end pess-multiple-storage-read

    /// @notice Processes a single attester unstake attempt.
    /// @param rollup The rollup staking interface.
    /// @param attester The attester address to process.
    /// @param info The attester info storage reference.
    /// @return exitAmount The unstake amount initiated for the attester.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start pess-multiple-storage-read
    function _processUnstakeAttester(IAztecRollup rollup, address attester, AttesterInfo storage info)
        internal
        returns (uint256 exitAmount)
    {
        AttesterView memory view_ = rollup.getAttesterView(attester);

        if (!view_.exit.exists) {
            exitAmount = view_.effectiveBalance;

            // slither-disable-next-line reentrancy-no-eth
            try rollup.initiateWithdraw(attester, address(this)) returns (bool isInitiated) {
                if (!isInitiated) {
                    revert StakingManager__UnstakeFailed(attester);
                }
            } catch (bytes memory reason) {
                if (exitAmount == 0) {
                    uint256 cachedStake = info.stakedAmount;
                    // Aztec fully slashed this attester when it reports no exit and no effective balance.
                    // The withdraw revert data is emitted so operators can audit each local purge.
                    _setAttesterStatus(attester, info, InternalAttesterStatus.Exiting);
                    _removeStakedAmount(attester, cachedStake);
                    _aggregateState.slashingDelta += cachedStake;
                    emit FullySlashedAttesterPurged(attester, cachedStake, reason);
                    _removeAttester(attester);
                    return 0;
                }
                revert StakingManager__UnstakeFailed(attester);
            }
        } else {
            // Existing exits may be zombie exits where the recoverable stake is in exit.amount
            exitAmount = view_.exit.amount;

            if (!view_.exit.isRecipient) {
                // slither-disable-next-line reentrancy-no-eth
                try rollup.initiateWithdraw(attester, address(this)) returns (bool isInitiated) {
                    if (!isInitiated) {
                        revert StakingManager__UnstakeFailed(attester);
                    }
                    return _finalizeUnstakeInitiation(rollup, attester, info, exitAmount);
                } catch {
                    revert StakingManager__UnstakeFailed(attester);
                }
            }
        }

        return _finalizeUnstakeInitiation(rollup, attester, info, exitAmount);
    }

    /// @notice Finalizes local accounting after a rollup unstake has been initiated.
    /// @param rollup The rollup staking interface.
    /// @param attester The attester address to process.
    /// @param info The attester info storage reference.
    /// @param exitAmount The unstake amount initiated for the attester.
    /// @return The unstake amount initiated for the attester.
    function _finalizeUnstakeInitiation(
        IAztecRollup rollup,
        address attester,
        AttesterInfo storage info,
        uint256 exitAmount
    ) internal returns (uint256) {
        _setAttesterStatus(attester, info, InternalAttesterStatus.Exiting);
        uint256 cachedStake = info.stakedAmount;
        info.stakedAmount = 0;
        info.exitRollup = address(rollup);
        info.pendingExitAmount = SafeCast.toUint96(exitAmount);

        // Update running state: subtract the full cached balance (not just the exit amount)
        // to avoid leaving a phantom when the attester was slashed before unstaking.
        _removeStakedAmount(attester, cachedStake);
        _aggregateState.pendingUnstakeAmount += exitAmount;

        // Record the slashing gap so OllaCore's accounting sees it.
        if (cachedStake > exitAmount) {
            _aggregateState.slashingDelta += (cachedStake - exitAmount);
        }

        emit UnstakeInitiated(attester, exitAmount);
        return exitAmount;
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    /// @notice Refreshes a single attester's cached state from the rollup.
    /// @dev Reads rollup state (source of truth), delta-updates the aggregate accumulator,
    ///      and finalizes exits when exitable. Silently skips unknown attesters.
    ///      Active attesters are queried on the canonical rollup (they follow upgrades via GSE).
    ///      Queued attesters are queried on queueRollup first, then canonical if queueRollup reports no state.
    ///      Exiting attesters are queried on their stored exitRollup to prevent phantom credits
    ///      after a rollup upgrade (exit state is local to the rollup instance that initiated it).
    /// @param canonicalRollup The current canonical rollup interface.
    /// @param attester The attester address to refresh.
    // slither-disable-start calls-loop
    // slither-disable-start costly-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-no-eth
    // slither-disable-start pess-multiple-storage-read
    // slither-disable-next-line cyclomatic-complexity
    function _refreshSingleAttester(IAztecRollup canonicalRollup, address attester) internal {
        AttesterInfo storage info = _attesterMap[attester];
        if (info.attester == address(0)) return; // Unknown attester -- skip silently

        // Exiting/queued attesters must be queried on the rollup where that local state lives.
        IAztecRollup rollup = canonicalRollup;
        if (info.status == InternalAttesterStatus.Exiting && info.exitRollup != address(0)) {
            rollup = IAztecRollup(info.exitRollup);
        } else if (info.status == InternalAttesterStatus.Queued && info.queueRollup != address(0)) {
            rollup = IAztecRollup(info.queueRollup);
        }

        // slither-disable-next-line calls-loop
        AttesterView memory view_ = rollup.getAttesterView(attester);
        bool zombieExitClaimed = false;

        // Handle Queued attesters: check if the rollup has activated them.
        if (info.status == InternalAttesterStatus.Queued) {
            if (view_.status == Status.NONE && !view_.exit.exists && view_.effectiveBalance == 0) {
                if (address(rollup) == address(canonicalRollup)) return;

                AttesterView memory canonicalView = canonicalRollup.getAttesterView(attester);
                if (
                    canonicalView.status == Status.NONE && !canonicalView.exit.exists
                        && canonicalView.effectiveBalance == 0
                ) {
                    return;
                }

                rollup = canonicalRollup;
                view_ = canonicalView;
            }
            info.queueRollup = address(0);
            _setAttesterStatus(attester, info, InternalAttesterStatus.Active);
        }

        uint256 oldBalance = info.stakedAmount;
        uint256 newBalance = view_.effectiveBalance;

        // Delta-update stakedAmount
        if (newBalance > oldBalance) {
            _aggregateState.stakedAmount += (newBalance - oldBalance);
        } else if (newBalance < oldBalance) {
            uint256 decrease = oldBalance - newBalance;
            _removeStakedAmount(attester, decrease);

            // Detect slashing: balance decreased but no exit initiated
            if (info.status == InternalAttesterStatus.Active && !view_.exit.exists) {
                _aggregateState.slashingDelta += decrease;
            }
        }

        // Handle Active attesters with an exit (externally initiated exit)
        if (info.status == InternalAttesterStatus.Active && view_.exit.exists) {
            // Zombie exit (isRecipient=false): claim it by calling initiateWithdraw to set recipient
            if (!view_.exit.isRecipient) {
                // slither-disable-next-line calls-loop,unused-return
                try rollup.initiateWithdraw(attester, address(this)) returns (bool isInitiated) {
                    zombieExitClaimed = isInitiated;
                } catch { }
            }
            _setAttesterStatus(attester, info, InternalAttesterStatus.Exiting);
            uint256 exitAmount = view_.exit.amount;
            info.exitRollup = address(rollup);
            info.pendingExitAmount = SafeCast.toUint96(exitAmount);
            _aggregateState.pendingUnstakeAmount += exitAmount;

            // Track slashing loss for externally-exited attesters: the difference between
            // what was staked and what the exit recovers is a slashing loss.
            if (oldBalance > exitAmount) {
                _aggregateState.slashingDelta += (oldBalance - exitAmount);
            }
        }

        // Handle Active attesters that were externally fully exited (no exit record, zero balance)
        if (info.status == InternalAttesterStatus.Active && !view_.exit.exists && newBalance == 0) {
            _setAttesterStatus(attester, info, InternalAttesterStatus.Exiting);
            _removeAttester(attester);
            emit AttesterStateRefreshed(attester, oldBalance, newBalance);
            return;
        }

        // Handle Exiting attesters
        if (info.status == InternalAttesterStatus.Exiting) {
            if (!view_.exit.exists) {
                // Externally finalized -- reconcile accounting and remove.
                //
                // NOTE: pendingExitAmount is the amount snapshotted at exit initiation. If the
                // Aztec rollup slashed this attester during the exit delay, exit.amount would have
                // been reduced on-chain, but the exit record is now deleted so the post-slash value
                // is unrecoverable. In that case pendingExit overstates the actual finalized amount.
                //
                // This is acceptable because:
                //  1. Net totalAssets remains correct: the over-reduction of stakedPrincipal via
                //     exitAmount is offset by fewer tokens arriving in the vault.
                //  2. Aztec's slashing pipeline (consensus + veto window, see StakingLib.sol and
                //     Slasher.sol in AztecProtocol/l1-contracts) ensures slashes finalize well
                //     before the exit delay expires, giving keepers ample time to call
                //     refreshAttesterState and route through the normal exitable path (which reads
                //     the correct view_.exit.amount).
                //  3. slashingDelta will not record this loss (the exit record is deleted, so the
                //     actual finalized amount is unrecoverable). The normal exitable path now
                //     captures exit-delay slashes in slashingDelta, so this externally-finalized
                //     edge case is the only remaining gap.
                uint256 pendingExit = info.pendingExitAmount;
                _removePendingUnstakeAmount(attester, pendingExit);
                _pendingClaimAmount += pendingExit;

                _removeAttester(attester);
                emit AttesterStateRefreshed(attester, oldBalance, newBalance);
                return;
            } else {
                if (!view_.exit.isRecipient && !zombieExitClaimed) {
                    // Retry zombie-exit claiming on each refresh. A revert here should not DoS the batch;
                    // the exit remains tracked on exitRollup and can be claimed by a later refresh.
                    // slither-disable-next-line calls-loop,unused-return
                    try rollup.initiateWithdraw(attester, address(this)) returns (bool isInitiated) {
                        if (!isInitiated) {
                            info.stakedAmount = newBalance;
                            emit AttesterStateRefreshed(attester, oldBalance, newBalance);
                            return;
                        }
                    } catch {
                        info.stakedAmount = newBalance;
                        emit AttesterStateRefreshed(attester, oldBalance, newBalance);
                        return;
                    }
                }

                _reconcileExitingExitAmount(attester, info, view_.exit.amount);

                if (!_isExitFinalizable(view_)) {
                    info.stakedAmount = newBalance;
                    emit AttesterStateRefreshed(attester, oldBalance, newBalance);
                    return;
                }

                // Exitable -- finalize the exit
                uint256 exitAmount = view_.exit.amount;
                uint256 pendingExit = info.pendingExitAmount;

                // slither-disable-next-line calls-loop
                try rollup.finalizeWithdraw(attester) { }
                catch {
                    info.stakedAmount = newBalance;
                    emit AttesterStateRefreshed(attester, oldBalance, newBalance);
                    return;
                }

                _removeAttester(attester);
                emit UnstakeFinalized(attester, exitAmount);
                _pendingClaimAmount += exitAmount;

                _removePendingUnstakeAmount(attester, pendingExit);

                // Attester removed -- skip balance update below
                emit AttesterStateRefreshed(attester, oldBalance, newBalance);
                return;
            }
        }

        // Update cached balance for delta tracking
        info.stakedAmount = newBalance;
        emit AttesterStateRefreshed(attester, oldBalance, newBalance);
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end costly-loop
    // slither-disable-end calls-loop

    // slither-disable-start pess-multiple-storage-read
    /// @notice Reconciles a pending exit snapshot against the current rollup exit amount.
    /// @dev Used while an attester remains in the Exiting state and the rollup exit record still
    ///      exists, so slashes during the exit delay are reflected before finalization.
    /// @param attester The attester being reconciled.
    /// @param info The attester info storage reference.
    /// @param exitAmount The current exit amount reported by the rollup.
    function _reconcileExitingExitAmount(address attester, AttesterInfo storage info, uint256 exitAmount) internal {
        uint256 pendingExit = info.pendingExitAmount;
        if (pendingExit <= exitAmount) {
            return;
        }

        uint256 decrease = pendingExit - exitAmount;
        info.pendingExitAmount = SafeCast.toUint96(exitAmount);

        _removePendingUnstakeAmount(attester, decrease);
        _aggregateState.slashingDelta += decrease;
    }

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
    /// @param activationThresholdValue The stake amount per attester.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    function _stakeAttesters(IAztecRollup rollup, uint256 attestersToStakeTo, uint256 activationThresholdValue)
        internal
        returns (uint256 stakedCount)
    {
        for (uint256 i; i < attestersToStakeTo; ++i) {
            if (gasleft() < _gasThreshold) {
                break;
            }
            KeyStore memory keyStore = stakingProviderRegistry.getAttesterKeystore();
            _setQueued(keyStore.attester, activationThresholdValue, address(rollup));
            emit StakedWithProvider(keyStore.attester, activationThresholdValue);
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
            ++stakedCount;
        }
        return stakedCount;
    }

    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    /// @notice Ensures the current canonical rollup is persisted for reward tracking.
    /// @return canonicalRollup The current canonical rollup address.
    function _ensureCanonicalRewardRollup() internal returns (address canonicalRollup) {
        canonicalRollup = rollupRegistry.getCanonicalRollup();
        _trackRewardRollup(canonicalRollup);
        return canonicalRollup;
    }

    /// @notice Adds a rollup to reward tracking if absent.
    /// @param rollupAddress The rollup address to track.
    function _trackRewardRollup(address rollupAddress) internal {
        if (_isRewardRollup[rollupAddress]) return;
        if (!_isExpectedRewardAsset()) return;
        _isRewardRollup[rollupAddress] = true;
        _rewardRollups.push(rollupAddress);
        emit RewardRollupTracked(rollupAddress);
    }

    /// @notice Removes a tracked reward rollup by index.
    /// @param index The index to remove.
    // slither-disable-next-line pess-multiple-storage-read
    function _removeRewardRollupAt(uint256 index) internal {
        address[] storage rewardRollups = _rewardRollups;
        address rollupAddress = rewardRollups[index];
        uint256 lastIndex = rewardRollups.length - 1;
        if (index != lastIndex) {
            rewardRollups[index] = rewardRollups[lastIndex];
        }
        rewardRollups.pop();
        // slither-disable-next-line costly-loop
        delete _isRewardRollup[rollupAddress];
        emit RewardRollupRemoved(rollupAddress);
    }

    /// @notice Removes a tracked reward rollup by address.
    /// @param rollupAddress The rollup address to remove.
    function _removeRewardRollup(address rollupAddress) internal {
        address[] storage rewardRollups = _rewardRollups;
        uint256 length = rewardRollups.length;
        for (uint256 i; i < length; ++i) {
            if (rewardRollups[i] == rollupAddress) {
                _removeRewardRollupAt(i);
                return;
            }
        }
        revert StakingManager__RewardRollupNotTracked(rollupAddress);
    }

    /// @notice Returns true when Aztec sequencer rewards are paid in the configured staking asset.
    /// @return True if the registry reward distributor uses the expected reward asset.
    function _isExpectedRewardAsset() internal view returns (bool) {
        return rollupRegistry.getRewardDistributor().ASSET() == stakingAsset;
    }

    /// @notice Returns true if an exit is present and finalizable through governance.
    /// @param view_ The attester view data.
    /// @return True if the exit is available to finalize.
    function _isExitFinalizable(AttesterView memory view_) internal view returns (bool) {
        if (!view_.exit.exists) {
            return false;
        }
        // Timestamp used only to gate exit readiness from rollup and governance state.
        // slither-disable-next-line timestamp
        if (Timestamp.unwrap(view_.exit.exitableAt) > block.timestamp) {
            return false;
        }

        // slither-disable-next-line calls-loop
        IAztecGovernance.Withdrawal memory withdrawal =
            IAztecGovernance(rollupRegistry.getGovernance()).getWithdrawal(view_.exit.withdrawalId);
        if (withdrawal.claimed) {
            return true;
        }
        if (withdrawal.recipient == address(0)) {
            return false;
        }

        // slither-disable-next-line timestamp
        return Timestamp.unwrap(withdrawal.unlocksAt) <= block.timestamp;
    }

    /// @notice Returns the canonical rollup address and interface.
    /// @return rollupAddress The canonical rollup address.
    /// @return rollup The rollup staking interface.
    function _getRollup() internal view returns (address rollupAddress, IAztecRollup rollup) {
        rollupAddress = rollupRegistry.getCanonicalRollup();
        rollup = IAztecRollup(rollupAddress);
        return (rollupAddress, rollup);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != governanceUpgradeAuthority) {
            revert StakingManager__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert StakingManager__ZeroAddress("newImplementation");
        }
    }

    /// @notice Calculates the attester count to stake to, bounded by available keys.
    /// @param amount The stake amount requested.
    /// @param activationThresholdValue The stake amount per attester.
    /// @param availableKeys The number of keys available in the queue.
    /// @return attestersToStakeTo The number of attesters to stake.
    function _calculateAttestersToStake(uint256 amount, uint256 activationThresholdValue, uint256 availableKeys)
        internal
        pure
        returns (uint256 attestersToStakeTo)
    {
        attestersToStakeTo = amount / activationThresholdValue;
        if (attestersToStakeTo > availableKeys) {
            attestersToStakeTo = availableKeys;
        }
        return attestersToStakeTo;
    }
}
