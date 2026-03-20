// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { OwnableUpgradeable } from "@oz-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@oz/utils/math/SafeCast.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { EnumerableSet } from "@oz/utils/structs/EnumerableSet.sol";
import { IAztecRollup } from "src/staking/interfaces/IAztecRollup.sol";
import { IAztecRollupRegistry } from "src/staking/interfaces/IAztecRollupRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { AttesterView, Status, Timestamp } from "src/staking/libraries/AztecTypes.sol";

// solhint-disable max-states-count
/// @title StakingManager
/// @notice Manages staking delegation, attester keys, and reward harvesting.
/// @dev Uses mapping-based attester registry with an EnumerableSet for active attesters
///      and an incremental running state accumulator.
/// @author Olla Core contributors
contract StakingManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuard, IStakingManager {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum allowed gas threshold (30 million).
    uint256 private constant _MAX_GAS_THRESHOLD = 30_000_000;

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

    /// @dev Mapping-based attester registry. O(1) access by address.
    mapping(address attester => AttesterInfo info) private _attesterMap;

    /// @dev Incrementally maintained aggregate staking state accumulator.
    StakingState private _aggregateState;

    /// @dev Enumerable set of active attester addresses for internal iteration (unstake).
    EnumerableSet.AddressSet private _activeAttesterSet;

    /// @notice Storage gap for future upgrades.
    // slither-disable-next-line unused-state
    uint256[52] private __gap;

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

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin_);
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
    function getUnstakedFunds()
        external
        override
        onlyCore
        nonReentrant
        returns (uint256 received, uint256 exitAmount, bool hasRemainingExits)
    {
        exitAmount = _pendingClaimAmount;
        _pendingClaimAmount = 0;

        uint256 balance = stakingAsset.balanceOf(address(this));
        if (balance > 0) {
            stakingAsset.safeTransfer(core, balance);
            emit UnstakedFundsClaimed(balance);
        }
        received = balance;
        hasRemainingExits = _exitingCount > 0;
        return (received, exitAmount, hasRemainingExits);
    }

    /// @inheritdoc IStakingManager
    function harvestRewards() external override onlyCore nonReentrant returns (uint256 harvested) {
        (, IAztecRollup rollup) = _getRollup();
        try rollup.claimSequencerRewards(rewardsAccumulator) returns (uint256 claimed) {
            harvested = claimed;
        } catch (bytes memory reason) {
            emit RewardsHarvestFailed(reason);
            return 0;
        }
        emit RewardsHarvested(harvested);
        return harvested;
    }

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
    function getClaimableRewards() external view override onlyCore returns (uint256 claimableRewards) {
        (, IAztecRollup rollup) = _getRollup();
        return rollup.getSequencerRewards(address(rewardsAccumulator));
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
    function hasExitableUnstakes() external view override returns (bool) {
        return _pendingClaimAmount > 0;
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
        return _aggregateState.stakedAmount + _aggregateState.pendingUnstakeAmount + _pendingClaimAmount;
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

            /// @dev guard to prevent futue code regressions, this path should never be triggerable
        } else if (status == InternalAttesterStatus.Active) {
            revert StakingManager__RemoveAttesterFailed(attester);
        }

        delete _attesterMap[attester];
        --_attesterCount;

        emit AttesterRemoved(attester);
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end costly-loop

    // slither-disable-start pess-multiple-storage-read
    /// @notice Marks an attester as active in the registry and updates running state.
    /// @param attester The attester address.
    /// @param stakedAmount The amount staked for this attester.
    function _setActive(address attester, uint256 stakedAmount) internal {
        AttesterInfo storage info = _attesterMap[attester];
        if (info.attester != address(0)) {
            revert StakingManager__AttesterAlreadyActive(attester);
        }
        info.attester = attester;
        info.stakedAmount = stakedAmount;
        ++_attesterCount;
        _setAttesterStatus(attester, info, InternalAttesterStatus.Active);
        _aggregateState.stakedAmount += stakedAmount;
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
        exitAmount = view_.effectiveBalance;

        // slither-disable-next-line reentrancy-no-eth
        bool isInitiated = rollup.initiateWithdraw(attester, address(this));
        if (!isInitiated) {
            if (view_.exit.exists) {
                _setAttesterStatus(attester, info, InternalAttesterStatus.Exiting);
                return 0;
            }
            revert StakingManager__UnstakeFailed(attester);
        }

        _setAttesterStatus(attester, info, InternalAttesterStatus.Exiting);
        uint256 cachedStake = info.stakedAmount;
        info.stakedAmount = 0;
        info.exitRollup = address(rollup);
        info.pendingExitAmount = SafeCast.toUint96(exitAmount);

        // Update running state: subtract the full cached balance (not just the exit amount)
        // to avoid leaving a phantom when the attester was slashed before unstaking.
        if (_aggregateState.stakedAmount >= cachedStake) {
            _aggregateState.stakedAmount -= cachedStake;
        } else {
            _aggregateState.stakedAmount = 0;
        }
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

        // Exiting attesters must be queried on the rollup where their exit was initiated,
        // because exit state is local to each rollup instance and does not migrate on upgrade.
        IAztecRollup rollup = (info.status == InternalAttesterStatus.Exiting && info.exitRollup != address(0))
            ? IAztecRollup(info.exitRollup)
            : canonicalRollup;

        // slither-disable-next-line calls-loop
        AttesterView memory view_ = rollup.getAttesterView(attester);

        // Attester is still in the rollup's entry queue (not yet activated in the GSE).
        // The rollup returns Status.NONE with zero balance and empty config for queued attesters.
        // Skip refresh -- there is no on-chain state to reconcile yet.
        if (
            info.status == InternalAttesterStatus.Active && view_.status == Status.NONE
                && view_.config.withdrawer == address(0) && !view_.exit.exists
        ) {
            return;
        }

        uint256 oldBalance = info.stakedAmount;
        uint256 newBalance = view_.effectiveBalance;

        // Delta-update stakedAmount
        if (newBalance > oldBalance) {
            _aggregateState.stakedAmount += (newBalance - oldBalance);
        } else if (newBalance < oldBalance) {
            uint256 decrease = oldBalance - newBalance;
            if (_aggregateState.stakedAmount >= decrease) {
                _aggregateState.stakedAmount -= decrease;
            } else {
                _aggregateState.stakedAmount = 0;
            }

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
                rollup.initiateWithdraw(attester, address(this));
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
                //  3. slashingDelta will not record this loss; safety-module monitoring should not
                //     rely solely on slashingDelta for exiting-attester slashes.
                uint256 pendingExit = info.pendingExitAmount;
                if (_aggregateState.pendingUnstakeAmount >= pendingExit) {
                    _aggregateState.pendingUnstakeAmount -= pendingExit;
                } else {
                    _aggregateState.pendingUnstakeAmount = 0;
                }
                _pendingClaimAmount += pendingExit;
                _removeAttester(attester);
            } else if (_isExitExitable(view_)) {
                // Exitable -- finalize the exit
                uint256 exitAmount = view_.exit.amount;
                uint256 pendingExit = info.pendingExitAmount;

                _removeAttester(attester);
                emit UnstakeFinalized(attester, exitAmount);
                // slither-disable-next-line calls-loop
                rollup.finalizeWithdraw(attester);

                _pendingClaimAmount += exitAmount;

                if (_aggregateState.pendingUnstakeAmount >= pendingExit) {
                    _aggregateState.pendingUnstakeAmount -= pendingExit;
                } else {
                    _aggregateState.pendingUnstakeAmount = 0;
                }

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
            _setActive(keyStore.attester, activationThresholdValue);
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

    /// @notice Returns true if an exit is present and exitable.
    /// @param view_ The attester view data.
    /// @return True if the exit is available to finalize.
    function _isExitExitable(AttesterView memory view_) internal view returns (bool) {
        if (!view_.exit.exists) {
            return false;
        }
        // Timestamp used only to gate exit readiness from the rollup state.
        // slither-disable-next-line timestamp
        return Timestamp.unwrap(view_.exit.exitableAt) < block.timestamp + 1;
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
        if (msg.sender != OwnableUpgradeable(core).owner()) {
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
