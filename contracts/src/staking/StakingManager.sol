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
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { AttesterView, Timestamp } from "src/staking/libraries/AztecTypes.sol";

// solhint-disable max-states-count
/// @title StakingManager
/// @notice Manages staking delegation, attester keys, and reward harvesting.
/// @author Olla Core contributors
contract StakingManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuard, IStakingManager {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for operator access control.
    bytes32 public constant OPERATOR_ROLE = RolesLib.OPERATOR_ROLE;

    /// @notice Default maximum age (in seconds) for slashing delta freshness.
    uint256 public constant DEFAULT_SLASHING_DELTA_MAX_AGE = 12 hours;

    /*//////////////////////////////////////////////////////////////
                                    STATE
    //////////////////////////////////////////////////////////////*/

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

    /// @notice The StakingProviderRegistry contract.
    IStakingProviderRegistry public stakingProviderRegistry;

    /// @dev Unified attester registry.
    IStakingManager.AttesterInfo[] private _attesters;

    /// @dev Stores index+1 so 0 can mean "not present" (index is value-1).
    /// @dev Mapping from attester to index plus one in _attesters.
    mapping(address attester => uint256 indexPlusOne) private _attesterIndex;

    /// @dev Count of active attesters in the registry.
    uint256 private _activeCount;

    /// @dev Count of exiting attesters in the registry.
    uint256 private _exitingCount;

    /// @dev Cumulative slashing delta tracked across rollup snapshots.
    uint256 private _cumulativeSlashingDelta;

    /// @dev Timestamp of the last completed slashing delta update.
    uint256 private _lastSlashingDeltaTimestamp;

    /// @dev Maximum allowed age for the cached slashing delta.
    uint256 private _slashingDeltaMaxAge;

    /// @dev Cursor for bounded unstake initiation.
    uint256 private _unstakeCursor;

    /// @dev Cursor for bounded finalize of pending unstakes.
    uint256 private _finalizeCursor;

    /// @dev Cursor for bounded active attester sync.
    uint256 private _activeSyncCursor;

    /// @dev Cursor for bounded attester state accumulation.
    uint256 private _attesterStateCursor;

    /// @dev Accumulator for bounded slashing delta computation.
    uint256 private _slashingDeltaAccumulated;

    /// @dev Accumulator for bounded staked total computation.
    uint256 private _stakedTotalAccumulated;

    /// @dev Cached total staked principal from last completed attester state computation.
    uint256 private _cachedTotalStaked;

    /// @dev Cached pending unstake amount from last completed attester state computation.
    uint256 private _cachedPendingUnstakeAmount;

    /// @dev Cached withdrawable amount from last completed attester state computation.
    uint256 private _cachedWithdrawableAmount;

    /// @dev Accumulator for bounded pending unstake computation.
    uint256 private _pendingUnstakeAccumulated;

    /// @dev Accumulator for bounded withdrawable amount computation.
    uint256 private _withdrawableAccumulated;

    /// @dev Gas threshold for bounded rebalance work.
    // solhint-disable-next-line private-vars-leading-underscore
    uint256 private gasThreshold;

    /// @notice Storage gap for future upgrades.
    // slither-disable-next-line unused-state
    uint256[43] private __gap;

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
        address rewardsVault_,
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
        if (rewardsVault_ == address(0)) {
            revert StakingManager__ZeroAddress("rewardsVault");
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
        rewardsVault = rewardsVault_;
        core = core_;
        governance = defaultAdmin_;
        stakingProviderRegistry = IStakingProviderRegistry(stakingProviderRegistry_);
        gasThreshold = 50_000;
        _slashingDeltaMaxAge = DEFAULT_SLASHING_DELTA_MAX_AGE;
        _lastSlashingDeltaTimestamp = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin_);
        _grantRole(OPERATOR_ROLE, defaultAdmin_);
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

    /// @inheritdoc IStakingManager
    function setGasThreshold(uint256 threshold) external override onlyCore {
        if (threshold == 0) revert StakingManager__ZeroAmount();
        uint256 previousThreshold = gasThreshold;
        gasThreshold = threshold;
        emit GasThresholdUpdated(previousThreshold, threshold);
    }

    /// @inheritdoc IStakingManager
    function unstake(uint256 amount) external override onlyCore nonReentrant returns (uint256 unstakedAmount) {
        if (amount == 0) revert StakingManager__ZeroAmount();
        unstakedAmount = _unstake(amount);
        return unstakedAmount;
    }

    // slither-disable-start calls-loop
    // slither-disable-start pess-multiple-storage-read,cache-array-length
    /// @notice Syncs attesters with the rollup exit state.
    function syncAttesters() external override onlyCore nonReentrant {
        // TODO: research if we can assume moving with rollup is safe
        address rollupAddress = rollupRegistry.getCanonicalRollup();
        IAztecRollup rollup = IAztecRollup(rollupAddress);
        _syncAttesters(rollup);
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
                          PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function computeAttesterState()
        external
        override
        onlyRole(OPERATOR_ROLE)
        returns (uint256 slashingDelta, bool completed)
    {
        (, IAztecRollup rollup) = _getRollup();
        uint256 lastUpdated = _lastSlashingDeltaTimestamp;
        bool wasStale = _isSlashingDeltaStale();

        if (wasStale) {
            emit SlashingDeltaStale(lastUpdated, _slashingDeltaMaxAge);
        }

        (uint256 currentSlashingDelta, bool computationCompleted) = _computeAttesterStateInternal(rollup);
        uint256 cachedDelta = _cumulativeSlashingDelta;
        if (computationCompleted) {
            uint256 previousValue = cachedDelta;
            if (currentSlashingDelta > previousValue) {
                _cumulativeSlashingDelta = currentSlashingDelta;
                cachedDelta = currentSlashingDelta;
            }
            // Persist cached values from accumulators before reset
            _cachedTotalStaked = _stakedTotalAccumulated;
            _cachedPendingUnstakeAmount = _pendingUnstakeAccumulated;
            _cachedWithdrawableAmount = _withdrawableAccumulated;
            _lastSlashingDeltaTimestamp = block.timestamp;
            // Reset accumulators
            _stakedTotalAccumulated = 0;
            _slashingDeltaAccumulated = 0;
            _pendingUnstakeAccumulated = 0;
            _withdrawableAccumulated = 0;
            emit AttesterStateUpdated(
                cachedDelta, _cachedTotalStaked, _cachedPendingUnstakeAmount, _cachedWithdrawableAmount, block.timestamp
            );
        }

        slashingDelta = cachedDelta;
        completed = computationCompleted;
        return (slashingDelta, completed);
    }

    /// @inheritdoc IStakingManager
    function setSlashingDeltaMaxAge(uint256 maxAge) external override onlyRole(OPERATOR_ROLE) {
        if (maxAge == 0) {
            revert StakingManager__ZeroAmount();
        }
        uint256 oldMaxAge = _slashingDeltaMaxAge;
        _slashingDeltaMaxAge = maxAge;
        emit SlashingDeltaMaxAgeUpdated(oldMaxAge, maxAge);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the cached slashing delta.
    /// @return slashingDelta The cached slashing delta.
    function getSlashingDelta() external view override onlyCore returns (uint256 slashingDelta) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_lastSlashingDeltaTimestamp, _slashingDeltaMaxAge);
        }
        return _cumulativeSlashingDelta;
    }

    /// @notice Internal helper to get the claimable rewards.
    /// @dev Internal helper to get the claimable rewards.
    /// @return claimableRewards The total rewards claimable to rewards recipient.
    function getClaimableRewards() external view override onlyCore returns (uint256 claimableRewards) {
        (, IAztecRollup rollup) = _getRollup();
        return rollup.getSequencerRewards(address(rewardsVault));
    }

    /// @inheritdoc IStakingManager
    function getStakingState() external view override returns (StakingState memory state) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_lastSlashingDeltaTimestamp, _slashingDeltaMaxAge);
        }
        state.stakedAmount = _cachedTotalStaked;
        state.pendingUnstakeAmount = _cachedPendingUnstakeAmount;
        state.withdrawableAmount = _cachedWithdrawableAmount;
        return state;
    }

    /// @inheritdoc IStakingManager
    function pendingUnstakes() external view override returns (uint256 pendingUnstakeAmount) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_lastSlashingDeltaTimestamp, _slashingDeltaMaxAge);
        }
        return _cachedPendingUnstakeAmount;
    }

    /// @inheritdoc IStakingManager
    function hasExitableUnstakes() external view override returns (bool) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_lastSlashingDeltaTimestamp, _slashingDeltaMaxAge);
        }
        return _cachedWithdrawableAmount != 0;
    }

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256 stakedTotal) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_lastSlashingDeltaTimestamp, _slashingDeltaMaxAge);
        }
        return _cachedTotalStaked;
    }

    /// @inheritdoc IStakingManager
    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return stakingProviderRegistry.getStakingProviderConfig();
    }

    /// @inheritdoc IStakingManager
    function getUnstakeCursor() external view override returns (uint256 cursor) {
        return _unstakeCursor;
    }

    /// @inheritdoc IStakingManager
    function getSlashingDeltaLiveness()
        external
        view
        override
        returns (uint256 lastUpdated, uint256 maxAge, bool isStale)
    {
        lastUpdated = _lastSlashingDeltaTimestamp;
        maxAge = _slashingDeltaMaxAge;
        isStale = _isSlashingDeltaStale();
        return (lastUpdated, maxAge, isStale);
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
        uint256 indexPlusOne = _attesterIndex[attester];
        if (indexPlusOne == 0) {
            return false;
        }
        return _attesters[indexPlusOne - 1].state == IStakingManager.InternalAttesterState.Exiting;
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

    /// @dev Internal unstake implementation.
    /// @dev Uses single-loop logic that breaks when enough funds are unstaked.
    /// @param amount The amount to unstake.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    // Reentrancy safe: caller (unstake) has nonReentrant modifier
    //   also the called contract is trusted Aztec protocol contract
    // slither-disable-start reentrancy-no-eth
    function _unstake(uint256 amount) internal returns (uint256 unstakedAmount) {
        (, IAztecRollup rollup) = _getRollup();
        unstakedAmount = _initiateUnstakeRequests(rollup, amount);
        return unstakedAmount;
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
        uint256 sumOfExitAmounts = _finalizeUnstakes(rollup);
        claimed = _finalizeClaim(balanceBefore, sumOfExitAmounts);
        return claimed;
    }

    // slither-disable-end reentrancy-no-eth
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    /// @notice Gets an attester index, create a new attester if it doesn't exist yet.
    /// @param attester The attester address.
    /// @return index The index of the attester entry in in the attester list.
    function _getOrCreateAttester(address attester) internal returns (uint256 index) {
        uint256 indexPlusOne = _attesterIndex[attester];
        if (indexPlusOne == 0) {
            _attesters.push(
                IStakingManager.AttesterInfo({
                    attester: attester, stakedAmount: 0, state: IStakingManager.InternalAttesterState.Inactive
                })
            );
            index = _attesters.length - 1;
            _attesterIndex[attester] = index + 1;
        } else {
            index = indexPlusOne - 1;
        }
        return index;
    }

    /// @notice Sets an attester state and updates counters.
    /// @param index The index in the unified registry.
    /// @param newState The new local state.
    function _setState(uint256 index, IStakingManager.InternalAttesterState newState) internal {
        IStakingManager.InternalAttesterState previousState = _attesters[index].state;
        if (previousState == newState) {
            return;
        }
        if (previousState == IStakingManager.InternalAttesterState.Active) {
            --_activeCount;
        } else if (previousState == IStakingManager.InternalAttesterState.Exiting) {
            --_exitingCount;
        }
        if (newState == IStakingManager.InternalAttesterState.Active) {
            ++_activeCount;
        } else if (newState == IStakingManager.InternalAttesterState.Exiting) {
            ++_exitingCount;
        }
        _attesters[index].state = newState;
    }

    /// @notice Marks an attester as active in the registry.
    /// @param attester The attester address.
    /// @param stakedAmount The amount staked for this attester.
    function _setActive(address attester, uint256 stakedAmount) internal {
        uint256 index = _getOrCreateAttester(attester);
        IStakingManager.AttesterInfo storage attesterInfo = _attesters[index];
        attesterInfo.stakedAmount = stakedAmount;
        _setState(index, IStakingManager.InternalAttesterState.Active);
    }

    /// @notice Finalizes an exit by emitting and calling the rollup.
    /// @param rollup The rollup staking interface.
    /// @param attester The attester address.
    /// @param amount The finalized exit amount.
    // slither-disable-start reentrancy-benign
    // slither-disable-next-line reentrancy-no-eth
    function _finalizeExit(IAztecRollup rollup, address attester, uint256 amount) internal {
        emit UnstakeFinalized(attester, amount);
        // slither-disable-next-line calls-loop
        rollup.finalizeWithdraw(attester);
    }

    // slither-disable-end reentrancy-benign

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
            if (gasleft() < gasThreshold) {
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

    /// @notice Initiates unstake requests for activated attesters.
    /// @dev External calls inside loop are safe:
    ///      - rollup is a trusted Aztec contract
    ///      - attesters are permissioned
    ///      - failure should revert entire unstake operation
    /// @param rollup The rollup staking interface.
    /// @param amount The amount to unstake.
    /// @return totalUnstakedAmount The total amount initiated for unstake.
    // slither-disable-next-line pess-multiple-storage-read,cache-array-length
    function _initiateUnstakeRequests(IAztecRollup rollup, uint256 amount)
        internal
        onlyCore
        returns (uint256 totalUnstakedAmount)
    {
        uint256 attesterLength = _attesters.length;
        if (attesterLength == 0 || _activeCount == 0) {
            _unstakeCursor = 0;
            return 0;
        }

        uint256 i = _unstakeCursor;
        if (i > attesterLength - 1) {
            i = 0;
        }

        // Bounded by gasThreshold and cursor; external entrypoints are nonReentrant.
        // slither-disable-next-line cache-array-length,calls-loop
        for (; i < _attesters.length;) {
            if (gasleft() < gasThreshold) {
                break;
            }
            IStakingManager.AttesterInfo storage attesterInfo = _attesters[i];
            if (attesterInfo.state != IStakingManager.InternalAttesterState.Active) {
                ++i;
                continue;
            }
            uint256 exitAmount = _processUnstakeAttester(rollup, i, attesterInfo.attester, attesterInfo.stakedAmount);
            totalUnstakedAmount += exitAmount;
            if (totalUnstakedAmount > amount || totalUnstakedAmount == amount) {
                break;
            }
            ++i;
        }

        uint256 currentLength = _attesters.length;
        if (currentLength == 0 || i > currentLength - 1) {
            _unstakeCursor = 0;
        } else {
            _unstakeCursor = i;
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
    /// @return exitAmount The unstake amount initiated for the attester.
    // slither-disable-start calls-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start pess-multiple-storage-read
    // Slither: `_attesters` is a storage array requiring index-based access; caching the struct
    // into memory would add complexity without meaningful gas savings since each access targets
    // a different index/field.
    function _processUnstakeAttester(IAztecRollup rollup, uint256 index, address attester, uint256 stakedAmount)
        internal
        returns (uint256 exitAmount)
    {
        AttesterView memory view_ = rollup.getAttesterView(attester);
        exitAmount = view_.effectiveBalance;
        IStakingManager.AttesterInfo storage attesterInfo = _attesters[index];

        // External call is safe:
        // - rollup is a trusted Aztec contract
        // - onlyCore entrypoints are nonReentrant
        // slither-disable-next-line reentrancy-no-eth
        bool isInitiated = rollup.initiateWithdraw(attester, address(this));
        if (!isInitiated) {
            if (view_.exit.exists) {
                attesterInfo.stakedAmount = stakedAmount;
                _setState(index, IStakingManager.InternalAttesterState.Exiting);
                return 0;
            }
            revert StakingManager__UnstakeFailed(attester);
        }
        attesterInfo.stakedAmount = stakedAmount;
        _setState(index, IStakingManager.InternalAttesterState.Exiting);
        emit UnstakeInitiated(attester, exitAmount);
        return exitAmount;
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end reentrancy-benign
    // slither-disable-end calls-loop

    /// @notice Finalizes pending unstake requests that are exitable.
    /// @dev Reentrancy protection provided by external caller (getUnstakedFunds).
    /// @param rollup The rollup staking interface.
    /// @return sumOfExitAmounts The total amount finalized.
    function _finalizeUnstakes(IAztecRollup rollup) internal returns (uint256 sumOfExitAmounts) {
        sumOfExitAmounts = _finalizeExits(rollup);
        return sumOfExitAmounts;
    }

    /// @notice Finalizes exiting attesters that are exitable.
    /// @dev Reentrancy protection provided by external caller (getUnstakedFunds).
    /// @param rollup The rollup staking interface.
    /// @return sumOfExitAmounts The total amount finalized.
    // slither-disable-next-line calls-loop,costly-loop
    // slither-disable-start reentrancy-benign
    // slither-disable-start pess-multiple-storage-read,cache-array-length
    function _finalizeExits(IAztecRollup rollup) internal returns (uint256 sumOfExitAmounts) {
        uint256 attesterLength = _attesters.length;
        if (attesterLength == 0 || _exitingCount == 0) {
            _finalizeCursor = 0;
            return 0;
        }

        uint256 i = _finalizeCursor;
        if (i > attesterLength - 1) {
            i = 0;
        }

        // Bounded by gasThreshold and cursor; external entrypoints are nonReentrant.
        for (; i < _attesters.length;) {
            if (gasleft() < gasThreshold) {
                break;
            }
            IStakingManager.AttesterInfo storage attesterInfo = _attesters[i];
            if (attesterInfo.state != IStakingManager.InternalAttesterState.Exiting) {
                ++i;
                continue;
            }
            address attester = attesterInfo.attester;

            // slither-disable-next-line calls-loop -- trusted rollup, bounded by attester set size
            AttesterView memory view_ = rollup.getAttesterView(attester);
            if (!view_.exit.exists) {
                _setState(i, IStakingManager.InternalAttesterState.Inactive);
                ++i;
                continue;
            }
            if (!_isExitExitable(view_)) {
                ++i;
                continue;
            }
            sumOfExitAmounts += view_.exit.amount;
            _setState(i, IStakingManager.InternalAttesterState.Inactive);
            // slither-disable-next-line reentrancy-no-eth
            _finalizeExit(rollup, attester, view_.exit.amount);
            ++i;
        }

        uint256 currentLength = _attesters.length;
        if (currentLength == 0 || i > currentLength - 1) {
            _finalizeCursor = 0;
        } else {
            _finalizeCursor = i;
        }

        return sumOfExitAmounts;
    }

    // slither-disable-end pess-multiple-storage-read,cache-array-length
    // slither-disable-end reentrancy-benign

    /// @notice Syncs attesters internal state with rollup state.
    /// @dev Updates local state when exits are detected on the rollup.
    /// @param rollup The rollup staking interface.
    // slither-disable-next-line calls-loop,costly-loop
    // slither-disable-start pess-multiple-storage-read,cache-array-length
    function _syncAttesters(IAztecRollup rollup) internal {
        uint256 attesterLength = _attesters.length;
        if (attesterLength == 0 || _activeCount == 0) {
            _activeSyncCursor = 0;
            return;
        }

        uint256 i = _activeSyncCursor;
        if (i > attesterLength - 1) {
            i = 0;
        }

        for (; i < _attesters.length;) {
            if (gasleft() < gasThreshold) {
                break;
            }
            IStakingManager.AttesterInfo storage attesterInfo = _attesters[i];
            if (attesterInfo.state != IStakingManager.InternalAttesterState.Active) {
                ++i;
                continue;
            }
            // slither-disable-next-line calls-loop -- trusted rollup, bounded by gas/cursor
            AttesterView memory view_ = rollup.getAttesterView(attesterInfo.attester);
            if (view_.exit.exists) {
                _setState(i, IStakingManager.InternalAttesterState.Exiting);
            }
            ++i;
        }

        uint256 currentLength = _attesters.length;
        if (currentLength == 0 || i > currentLength - 1) {
            _activeSyncCursor = 0;
        } else {
            _activeSyncCursor = i;
        }
    }

    // slither-disable-end pess-multiple-storage-read,cache-array-length

    /// @notice Finalizes a claim by validating and transferring unstaked funds.
    /// @param balanceBefore The token balance before finalization.
    /// @param sumOfExitAmounts The sum of finalized exit amounts.
    /// @return claimed The amount claimed and transferred.
    function _finalizeClaim(uint256 balanceBefore, uint256 sumOfExitAmounts) internal returns (uint256 claimed) {
        uint256 balanceAfter = stakingAsset.balanceOf(address(this));
        uint256 newlyFinalized = balanceAfter - balanceBefore;
        if (sumOfExitAmounts != newlyFinalized) {
            revert StakingManager__ClaimAmountMismatch();
        }

        claimed = balanceAfter;
        if (claimed > 0) {
            stakingAsset.safeTransfer(core, claimed);
            emit UnstakedFundsClaimed(claimed);
        }
        return claimed;
    }

    function _computeAttesterStateInternal(IAztecRollup rollup)
        internal
        returns (uint256 slashingDelta, bool completed)
    {
        if (_attesterStateCursor == 0) {
            _stakedTotalAccumulated = 0;
            _slashingDeltaAccumulated = 0;
            _pendingUnstakeAccumulated = 0;
            _withdrawableAccumulated = 0;
        }

        (_stakedTotalAccumulated, _slashingDeltaAccumulated, _pendingUnstakeAccumulated, _withdrawableAccumulated) =
            _accumulateAttesterState(
                rollup,
                _stakedTotalAccumulated,
                _slashingDeltaAccumulated,
                _pendingUnstakeAccumulated,
                _withdrawableAccumulated
            );

        if (_attesterStateCursor == 0) {
            slashingDelta = _slashingDeltaAccumulated;
            completed = true;
        }
        return (slashingDelta, completed);
    }

    // Rollup is trusted and loop bounded by attester set size.
    // slither-disable-next-line calls-loop
    // slither-disable-next-line pess-multiple-storage-read -- length read + indexed access unavoidable in loop
    function _accumulateAttesterState(
        IAztecRollup rollup,
        uint256 stakedTotal,
        uint256 slashingDelta,
        uint256 pendingUnstake,
        uint256 withdrawable
    )
        internal
        returns (
            uint256 updatedTotalStaked,
            uint256 updatedSlashingDelta,
            uint256 updatedPendingUnstake,
            uint256 updatedWithdrawable
        )
    {
        uint256 length = _attesters.length;
        if (length == 0) {
            _attesterStateCursor = 0;
            return (stakedTotal, slashingDelta, pendingUnstake, withdrawable);
        }

        uint256 i = _attesterStateCursor;
        if (i > length - 1) {
            i = 0;
        }

        // Bounded by gasThreshold and cursor.
        for (; i < length;) {
            if (gasleft() < gasThreshold) {
                break;
            }
            IStakingManager.AttesterInfo storage attesterInfo = _attesters[i];
            IStakingManager.InternalAttesterState state = attesterInfo.state;
            if (
                state != IStakingManager.InternalAttesterState.Active
                    && state != IStakingManager.InternalAttesterState.Exiting
            ) {
                ++i;
                continue;
            }

            (stakedTotal, slashingDelta, pendingUnstake, withdrawable) =
                _computeAttesterState(rollup, attesterInfo, stakedTotal, slashingDelta, pendingUnstake, withdrawable);
            ++i;
        }

        _updateAttesterStateCursor(i);
        return (stakedTotal, slashingDelta, pendingUnstake, withdrawable);
    }

    /// @notice Updates the attester state cursor after iteration.
    /// @param i The current iterator position.
    function _updateAttesterStateCursor(uint256 i) internal {
        uint256 currentLength = _attesters.length;
        if (currentLength == 0 || i > currentLength - 1) {
            _attesterStateCursor = 0;
        } else {
            _attesterStateCursor = i;
        }
    }

    /// @notice Accumulates attester state for a single attester.
    /// @param rollup The rollup staking interface.
    /// @param attesterInfo The attester info storage reference.
    /// @param stakedTotal Running total of staked amounts.
    /// @param slashingDelta Running total of slashing delta.
    /// @param pendingUnstake Running total of pending unstake amounts.
    /// @param withdrawable Running total of withdrawable amounts.
    /// @return updatedStakedTotal Updated staked total.
    /// @return updatedSlashingDelta Updated slashing delta.
    /// @return updatedPendingUnstake Updated pending unstake total.
    /// @return updatedWithdrawable Updated withdrawable total.
    function _computeAttesterState(
        IAztecRollup rollup,
        IStakingManager.AttesterInfo storage attesterInfo,
        uint256 stakedTotal,
        uint256 slashingDelta,
        uint256 pendingUnstake,
        uint256 withdrawable
    )
        internal
        view
        returns (
            uint256 updatedStakedTotal,
            uint256 updatedSlashingDelta,
            uint256 updatedPendingUnstake,
            uint256 updatedWithdrawable
        )
    {
        // slither-disable-next-line calls-loop -- trusted rollup, bounded by gas/cursor
        AttesterView memory view_ = rollup.getAttesterView(attesterInfo.attester);
        (bool eligible, uint256 remaining) = _remainingStake(view_);
        if (!eligible) {
            return (stakedTotal, slashingDelta, pendingUnstake, withdrawable);
        }
        uint256 stakedAmount = attesterInfo.stakedAmount;
        stakedTotal += stakedAmount;
        if (stakedAmount > remaining) {
            slashingDelta += stakedAmount - remaining;
        }

        // Accumulate exit state
        if (view_.exit.exists) {
            if (_isExitExitable(view_)) {
                withdrawable += view_.exit.amount;
            } else {
                pendingUnstake += view_.exit.amount;
            }
        }

        return (stakedTotal, slashingDelta, pendingUnstake, withdrawable);
    }

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
        if (msg.sender != governance) {
            revert StakingManager__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert StakingManager__ZeroAddress("newImplementation");
        }
    }

    // Slither: zero-sentinel check (`== 0`) guards uninitialized state; `_lastSlashingDeltaTimestamp`
    // is only written to `block.timestamp` by `initialize()` and `computeAttesterState()`.
    // Timestamp comparison is intentional for liveness enforcement with a 12-hour window;
    // miner manipulation of a few seconds has no security impact.
    // slither-disable-next-line incorrect-equality,timestamp
    function _isSlashingDeltaStale() internal view returns (bool) {
        uint256 lastUpdated = _lastSlashingDeltaTimestamp;
        if (lastUpdated == 0) {
            return true;
        }
        return block.timestamp - lastUpdated > _slashingDeltaMaxAge;
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
