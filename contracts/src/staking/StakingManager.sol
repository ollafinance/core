// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";

import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { IAztecRollup } from "src/staking/interfaces/IAztecRollup.sol";
import { IAztecRollupRegistry } from "src/staking/interfaces/IAztecRollupRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { AttesterView, Status, Timestamp } from "src/staking/libraries/AztecTypes.sol";
import { RolesLib } from "src/shared/RolesLib.sol";

// solhint-disable max-states-count
/// @title StakingManager
/// @notice Manages staking delegation, attester keys, and reward harvesting.
/// @author Olla Core contributors
contract StakingManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuard, IStakingManager {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant OPERATOR_ROLE = RolesLib.OPERATOR_ROLE;
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

    /// @dev Cursor for bounded slashing delta accumulation.
    uint256 private _slashingDeltaCursor;

    /// @dev Accumulator for bounded slashing delta computation.
    uint256 private _slashingDeltaAccumulated;

    /// @dev Accumulator for bounded staked total computation.
    uint256 private _stakedTotalAccumulated;

    /// @dev Gas threshold for bounded rebalance work.
    // solhint-disable-next-line private-vars-leading-underscore
    uint256 private gasThreshold;

    /// @notice Storage gap for future upgrades.
    // slither-disable-next-line unused-state
    uint256[48] private __gap;

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

    /// @notice Returns the cached slashing delta.
    /// @return slashingDelta The cached slashing delta.
    function getSlashingDelta() external view override onlyCore returns (uint256 slashingDelta) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_lastSlashingDeltaTimestamp, _slashingDeltaMaxAge);
        }
        return _cumulativeSlashingDelta;
    }

    /*//////////////////////////////////////////////////////////////
                         PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function computeSlashingDelta()
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

        (uint256 currentSlashingDelta, bool computationCompleted) = _computeSlashed(rollup);
        if (computationCompleted) {
            uint256 previousValue = _cumulativeSlashingDelta;
            if (currentSlashingDelta > previousValue) {
                _cumulativeSlashingDelta = currentSlashingDelta;
            }
            _lastSlashingDeltaTimestamp = block.timestamp;
            emit SlashingDeltaUpdated(previousValue, _cumulativeSlashingDelta, block.timestamp);
        }

        slashingDelta = _cumulativeSlashingDelta;
        completed = computationCompleted;
        return (slashingDelta, completed);
    }

    /// @inheritdoc IStakingManager
    function setSlashingDeltaMaxAge(uint256 maxAge) external override onlyRole(OPERATOR_ROLE) {
        if (maxAge == 0) {
            revert StakingManager__ZeroAmount();
        }
        _slashingDeltaMaxAge = maxAge;
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
        return _getAttestersStakingState(rollup);
    }

    // slither-disable-end calls-loop,timestamp

    /// @inheritdoc IStakingManager
    function pendingUnstakes() external view override returns (uint256 pendingUnstakeAmount) {
        (, IAztecRollup rollup) = _getRollup();
        StakingState memory state = _getAttestersStakingState(rollup);
        pendingUnstakeAmount = state.pendingUnstakeAmount;
        return pendingUnstakeAmount;
    }

    /// @inheritdoc IStakingManager
    function hasExitableUnstakes() external view override returns (bool) {
        (, IAztecRollup rollup) = _getRollup();
        StakingState memory state = _getAttestersStakingState(rollup);
        if (state.withdrawableAmount != 0) {
            return true;
        }
        return false;
    }

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256 stakedTotal) {
        // TODO: research if we can assume moving with rollup is safe
        (, IAztecRollup rollup) = _getRollup();
        stakedTotal = _computeStaked(rollup);
        return stakedTotal;
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
    // slither-disable-next-line pess-multiple-storage-read -- _setState reads _attesters; caching here won't remove warning
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

    /// @notice Syncs active attesters with rollup exit state.
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

    function _computeSlashed(IAztecRollup rollup) internal returns (uint256 slashingDelta, bool completed) {
        if (_slashingDeltaCursor == 0) {
            _stakedTotalAccumulated = 0;
            _slashingDeltaAccumulated = 0;
        }

        (_stakedTotalAccumulated, _slashingDeltaAccumulated) =
            _accumulateAttestersDelta(rollup, _stakedTotalAccumulated, _slashingDeltaAccumulated);

        if (_slashingDeltaCursor == 0) {
            slashingDelta = _slashingDeltaAccumulated;
            completed = true;
            _stakedTotalAccumulated = 0;
            _slashingDeltaAccumulated = 0;
        }
        return (slashingDelta, completed);
    }

    // Rollup is trusted and loop bounded by attester set size.
    // slither-disable-next-line calls-loop
    // slither-disable-next-line pess-multiple-storage-read -- length read + indexed access unavoidable in loop
    function _accumulateAttestersDelta(IAztecRollup rollup, uint256 stakedTotal, uint256 slashingDelta)
        internal
        returns (uint256 updatedTotalStaked, uint256 updatedSlashingDelta)
    {
        uint256 length = _attesters.length;
        if (length == 0) {
            _slashingDeltaCursor = 0;
            return (stakedTotal, slashingDelta);
        }

        uint256 i = _slashingDeltaCursor;
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
            address attester = attesterInfo.attester;
            uint256 stakedAmount = attesterInfo.stakedAmount;

            // slither-disable-next-line calls-loop -- trusted rollup, bounded by gas/cursor
            AttesterView memory view_ = rollup.getAttesterView(attester);
            (bool eligible, uint256 remaining) = _remainingStake(view_);
            if (!eligible) {
                ++i;
                continue;
            }
            stakedTotal += stakedAmount;
            if (stakedAmount > remaining) {
                slashingDelta += stakedAmount - remaining;
            }
            ++i;
        }

        uint256 currentLength = _attesters.length;
        if (currentLength == 0 || i > currentLength - 1) {
            _slashingDeltaCursor = 0;
        } else {
            _slashingDeltaCursor = i;
        }

        return (stakedTotal, slashingDelta);
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

    // slither-disable-start calls-loop,timestamp,pess-multiple-storage-read
    function _getAttestersStakingState(IAztecRollup rollup) internal view returns (StakingState memory state) {
        uint256 attesterLength = _attesters.length;
        for (uint256 i; i < attesterLength; ++i) {
            IStakingManager.AttesterInfo storage attesterInfo = _attesters[i];
            if (attesterInfo.state == IStakingManager.InternalAttesterState.Inactive) {
                continue;
            }

            AttesterView memory view_ = rollup.getAttesterView(attesterInfo.attester);
            if (attesterInfo.state == IStakingManager.InternalAttesterState.Active) {
                if (view_.status == Status.VALIDATING && view_.effectiveBalance > 0) {
                    state.stakedAmount += view_.effectiveBalance;
                }
                // Active entries can have rollup exits before local state sync.
                if (view_.exit.exists) {
                    if (_isExitExitable(view_)) {
                        state.withdrawableAmount += view_.exit.amount;
                    } else {
                        state.pendingUnstakeAmount += view_.exit.amount;
                    }
                }
                continue;
            }

            if (attesterInfo.state == IStakingManager.InternalAttesterState.Exiting && view_.exit.exists) {
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
        (stakedTotal,) = _accumulateAttestersDeltaView(rollup, 0, 0);
        return stakedTotal;
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
    // slither-disable-next-line pess-multiple-storage-read -- length read + indexed access unavoidable in loop
    function _accumulateAttestersDeltaView(IAztecRollup rollup, uint256 stakedTotal, uint256 slashingDelta)
        internal
        view
        returns (uint256 updatedTotalStaked, uint256 updatedSlashingDelta)
    {
        uint256 length = _attesters.length;
        for (uint256 i; i < length; ++i) {
            IStakingManager.AttesterInfo storage attesterInfo = _attesters[i];
            IStakingManager.InternalAttesterState state = attesterInfo.state;
            if (
                state != IStakingManager.InternalAttesterState.Active
                    && state != IStakingManager.InternalAttesterState.Exiting
            ) {
                continue;
            }
            address attester = attesterInfo.attester;
            uint256 stakedAmount = attesterInfo.stakedAmount;

            // slither-disable-next-line calls-loop -- trusted rollup, bounded by attester set size
            AttesterView memory view_ = rollup.getAttesterView(attester);
            (bool eligible, uint256 remaining) = _remainingStake(view_);
            if (!eligible) {
                continue;
            }
            stakedTotal += stakedAmount;
            if (stakedAmount > remaining) {
                slashingDelta += stakedAmount - remaining;
            }
        }
        return (stakedTotal, slashingDelta);
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

    function _isSlashingDeltaStale() internal view returns (bool) {
        uint256 lastUpdated = _lastSlashingDeltaTimestamp;
        if (lastUpdated == 0) {
            return true;
        }
        return block.timestamp - lastUpdated > _slashingDeltaMaxAge;
    }
}
