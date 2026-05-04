// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Ownable2StepUpgradeable } from "@oz-upgradeable/access/Ownable2StepUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { SafeCast } from "@oz/utils/math/SafeCast.sol";
import { ReentrancyGuardTransient } from "@oz/utils/ReentrancyGuardTransient.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { GovernanceLib } from "src/core/libraries/GovernanceLib.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { RolesLib } from "src/shared/RolesLib.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";

/// @title OllaCore
/// @notice Orchestration + accounting layer. Manages rebalance, computes totalAssets/exchangeRate,
///         interacts with StakingManager/RewardsAccumulator/SafetyModule, and instructs Vault via CORE_ROLE.
/// @dev This contract holds AZTEC tokens only transiently during rebalance operations.
///      Tokens sent directly to this address cannot be recovered. Users should interact
///      with OllaVault, which has `reconcileBufferedAssets()` for recovery.
/// @author Olla Core contributors
contract OllaCore is
    Initializable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    IOllaCore
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant _EXCHANGE_RATE_SCALE = 1e18;
    uint256 private constant _VIRTUAL_OFFSET = 1e3;
    uint256 private constant _REBALANCE_GAS_THRESHOLD = 180_000;

    /// @notice Role for guardian pause/unpause actions.
    bytes32 public constant GUARDIAN_ROLE = RolesLib.GUARDIAN_ROLE;

    /// @notice Basis points divisor.
    uint256 public constant BP_DIVISOR = 10_000;

    /// @notice Maximum protocol fee: 50%.
    uint256 public constant MAX_PROTOCOL_FEE_BP = 5_000;
    /// @notice Minimum treasury fee split: 10%.
    uint256 public constant MIN_TREASURY_SPLIT_BP = 1_000;
    /// @notice Maximum treasury fee split: 90%.
    uint256 public constant MAX_TREASURY_SPLIT_BP = 9_000;
    /// @notice Minimum rebalance gas threshold.
    uint256 public constant MIN_REBALANCE_GAS_THRESHOLD = 20_000;
    /// @notice Maximum rebalance gas threshold.
    uint256 public constant MAX_REBALANCE_GAS_THRESHOLD = 1_000_000;
    /// @notice Minimum allowed cooldown value.
    uint256 public constant MIN_REBALANCE_COOLDOWN = 10 minutes;
    /// @notice Maximum allowed cooldown value.
    uint256 public constant MAX_REBALANCE_COOLDOWN = 24 hours;

    /// @notice Minimum RewardsAccumulator balance considered actionable by the idle fast-path.
    /// @dev Balances at or below this threshold are treated as dust and do not bypass the idle
    ///      no-op short-circuit in `rebalance()`. This prevents griefers from consuming the
    ///      cooldown by donating tiny amounts to the accumulator.
    uint256 public constant REWARDS_ACCUMULATOR_DUST_THRESHOLD = 10_000 * 1e18;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract related interfaces and addresses.
    IOllaCore.CoreModules private _modules;

    /// @notice Protocol-internal ledger of cumulative rewards. Every other accounting figure is
    ///         derived live from the owning module via `_liveAccountingState()`.
    uint256 private _cumulativeRewards;
    IOllaCore.FlowCounters private _flowCounters;
    IOllaCore.LatestReport private _latestReport;

    IOllaCore.RebalanceProgress private _rebalanceProgress;

    /// @notice Snapshot of bufferedAssets at the end of an unproductive rebalance cycle.
    uint256 private _rebalanceIdleBuffer;

    /// @notice The protocol fee in basis points.
    uint16 public protocolFeeBP;

    /// @notice The treasury fee split in basis points.
    uint16 public treasuryFeeSplitBP;

    /// @notice Gas threshold used to gate rebalance step execution.
    uint32 public rebalanceGasThreshold;

    /// @notice Minimum seconds between permissionless rebalance cycles.
    uint32 public rebalanceCooldown;

    /// @notice Timestamp of the last completed rebalance cycle.
    uint48 public lastRebalanceTimestamp;

    /// @notice Exclusive withdrawal request id upper bound for the active rebalance cycle.
    uint256 private _rebalanceWithdrawalSnapshotEndId;

    /// @notice Storage gap for future upgrades.
    /// @dev When adding new state variables, append them above this gap and reduce its length
    ///      by the number of slots consumed. Target: 50 gap slots across all upgradeable contracts.
    // slither-disable-next-line unused-state
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when buffered assets do not match the vault balance.
    error OllaCore__BufferedBalanceMismatch(uint256 expected, uint256 actual);

    modifier whenRebalanceDone() {
        if (_rebalanceProgress.step != IOllaCore.RebalanceStep.Done) {
            revert OllaCore__RebalanceInProgress();
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
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaCore
    function initialize(
        IERC20 asset_,
        IStAztec stAztec_,
        IStakingManager stakingManager_,
        uint256 protocolFeeBP_,
        uint256 treasuryFeeSplitBP_,
        address governanceContract_,
        IRewardsAccumulator rewardsAccumulator_,
        address safetyModule_
    ) external override initializer {
        _validateInitialParams(
            asset_,
            stAztec_,
            stakingManager_,
            protocolFeeBP_,
            treasuryFeeSplitBP_,
            governanceContract_,
            rewardsAccumulator_,
            safetyModule_
        );
        __Ownable_init(governanceContract_);
        __AccessControl_init();
        __Pausable_init();
        _pause();

        _modules = IOllaCore.CoreModules({
            asset: asset_,
            vault: address(0), // Set via setVault() after vault deployment
            stAztec: stAztec_,
            stakingManager: stakingManager_,
            rewardsAccumulator: rewardsAccumulator_,
            safetyModule: safetyModule_
        });

        protocolFeeBP = SafeCast.toUint16(protocolFeeBP_);
        treasuryFeeSplitBP = SafeCast.toUint16(treasuryFeeSplitBP_);
        rebalanceGasThreshold = SafeCast.toUint32(_REBALANCE_GAS_THRESHOLD);
        _rebalanceProgress.step = IOllaCore.RebalanceStep.Done;

        _modules.stakingManager.setGasThreshold(rebalanceGasThreshold);

        _latestReport.exchangeRate = _EXCHANGE_RATE_SCALE;
        // Initial report timestamp set at deployment; miner manipulation is negligible.
        // slither-disable-next-line timestamp
        _latestReport.timestamp = block.timestamp;

        rebalanceCooldown = SafeCast.toUint32(1 hours);
        // Initial rebalance timestamp set at deployment; miner manipulation is negligible.
        // slither-disable-next-line timestamp
        lastRebalanceTimestamp = SafeCast.toUint48(block.timestamp);

        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, governanceContract_);
        _grantRole(GUARDIAN_ROLE, governanceContract_);
    }

    /*//////////////////////////////////////////////////////////////
                      PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaCore
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @inheritdoc IOllaCore
    /// @dev No cooldown between pause/unpause is intentional. A cooldown would slow recovery
    ///      after false alarms and does not meaningfully mitigate a compromised guardian key
    ///      (a single pause() is already a full DoS). Mitigation: guardian MUST be a multisig.
    ///      Recovery from compromised guardian: revoke GUARDIAN_ROLE via governance, grant to
    ///      new address, new guardian unpauses.
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /// @inheritdoc IOllaCore
    function forceRebalanceReset() external override onlyRole(GUARDIAN_ROLE) {
        _rebalanceProgress =
            IOllaCore.RebalanceProgress({ step: IOllaCore.RebalanceStep.Done, stakeRemaining: 0, unstakeRemaining: 0 });
        _rebalanceIdleBuffer = 0;
        lastRebalanceTimestamp = SafeCast.toUint48(block.timestamp);
        emit RebalanceReset();
    }

    /// @inheritdoc IOllaCore
    function setProtocolFeeBP(uint256 newFeeBP)
        external
        override
        onlyOwner
        whenNotPaused
        whenRebalanceDone
        nonReentrant
    {
        if (newFeeBP > MAX_PROTOCOL_FEE_BP) revert OllaCore__InvalidFeeBP(newFeeBP);
        _updateAccountingInternal();
        uint256 oldFeeBP = protocolFeeBP;
        protocolFeeBP = SafeCast.toUint16(newFeeBP);
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);
    }

    /// @inheritdoc IOllaCore
    function setTreasuryFeeSplitBP(uint256 newSplitBP)
        external
        override
        onlyOwner
        whenNotPaused
        whenRebalanceDone
        nonReentrant
    {
        if (newSplitBP < MIN_TREASURY_SPLIT_BP || newSplitBP > MAX_TREASURY_SPLIT_BP) {
            revert OllaCore__InvalidSplitBP(newSplitBP);
        }
        _updateAccountingInternal();
        uint256 oldSplitBP = treasuryFeeSplitBP;
        treasuryFeeSplitBP = SafeCast.toUint16(newSplitBP);
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);
    }

    /// @inheritdoc IOllaCore
    function setSafetyModule(address newSafetyModule) external override onlyOwner whenNotPaused whenRebalanceDone {
        address oldSafetyModule = GovernanceLib.setSafetyModule(_modules, newSafetyModule);
        emit SafetyModuleUpdated(oldSafetyModule, newSafetyModule);
        // Inlined from `_updateAccountingTimestamp` to keep that helper single-caller.
        // A second caller flips the optimizer's inlining decision and tips
        // `_computeAndFinalizeAccounting` past the 16-slot EVM stack limit under via_ir.
        // Recording the current timestamp is intentional; miner manipulation is negligible here.
        // slither-disable-next-line timestamp
        ISafetyModule(newSafetyModule).setLatestAccountingTimestamp(block.timestamp);
    }

    /// @inheritdoc IOllaCore
    function setRebalanceGasThreshold(uint256 newThreshold)
        external
        override
        onlyOwner
        whenNotPaused
        whenRebalanceDone
    {
        if (newThreshold < MIN_REBALANCE_GAS_THRESHOLD || newThreshold > MAX_REBALANCE_GAS_THRESHOLD) {
            revert OllaCore__InvalidGasThreshold(newThreshold);
        }
        uint256 oldThreshold = rebalanceGasThreshold;
        rebalanceGasThreshold = SafeCast.toUint32(newThreshold);
        emit RebalanceGasThresholdUpdated(oldThreshold, newThreshold);
        GovernanceLib.propagateGasThreshold(_modules, newThreshold);
    }

    /// @inheritdoc IOllaCore
    function setRebalanceCooldown(uint256 cooldown_) external override onlyOwner whenNotPaused whenRebalanceDone {
        if (cooldown_ < MIN_REBALANCE_COOLDOWN || cooldown_ > MAX_REBALANCE_COOLDOWN) {
            revert OllaCore__InvalidParameter();
        }
        uint256 old = rebalanceCooldown;
        rebalanceCooldown = SafeCast.toUint32(cooldown_);
        emit RebalanceCooldownUpdated(old, cooldown_);
    }

    /// @inheritdoc IOllaCore
    function setVault(address vault_) external override onlyOwner {
        if (vault_ == address(0)) revert OllaCore__ZeroAddress("vault_");
        if (_modules.vault != address(0)) revert OllaCore__VaultAlreadySet();
        _modules.vault = vault_;
        emit VaultSet(vault_);
    }

    /*//////////////////////////////////////////////////////////////
                        PERMISSIONLESS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // slither-disable-start cyclomatic-complexity
    // Rebalance is a multi-step state machine; high complexity is inherent.
    // slither-disable-start pess-multiple-storage-read
    // Multiple storage reads are required across state machine steps; caching would complicate the flow.
    // slither-disable-start incorrect-equality,timestamp
    // Enum/zero equality checks and block.timestamp cooldown comparisons are intentional throughout.
    // solhint-disable function-max-lines
    /// @inheritdoc IOllaCore
    function rebalance()
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer)
    {
        ISafetyModule safetyModuleRef = ISafetyModule(_modules.safetyModule);
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        // SafetyModule is a trusted protocol contract; call is guarded by nonReentrant.
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        safetyModuleRef.checkAccountingLiveness();
        IOllaCore.RebalanceProgress memory progress = _rebalanceProgress;

        // slither-disable-next-line incorrect-equality
        if (progress.step == IOllaCore.RebalanceStep.Done) {
            {
                uint256 cooldown_ = rebalanceCooldown;
                uint256 elapsed = block.timestamp - lastRebalanceTimestamp;
                // Standard cooldown check; miner manipulation (~15s) is negligible for this use case.
                // slither-disable-next-line timestamp
                if (elapsed < cooldown_) revert OllaCore__RebalanceCooldownActive(elapsed, cooldown_);
            }

            uint256 currentBuffer = vaultRef.bufferedAssets();
            // No-op early exit: intentionally does NOT update `_lastRebalanceTimestamp` or call
            // `_updateAccountingInternal()`. Updating the timestamp here would allow a griefing
            // attack where a caller triggers a no-op during an idle period, consuming the cooldown
            // window and blocking real rebalance work from being processed.
            if (_rebalanceIdleBuffer != 0 && currentBuffer == _rebalanceIdleBuffer && !_hasRebalanceWorkAvailable()) {
                return (0, 0, 0, currentBuffer);
            }
            _rebalanceIdleBuffer = 0;
            _rebalanceWithdrawalSnapshotEndId = 0;
            progress.step = IOllaCore.RebalanceStep.Harvest;
            progress.stakeRemaining = 0;
            progress.unstakeRemaining = 0;
        }

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.Harvest) {
            // Calls trusted RewardsAccumulator/StakingManager within nonReentrant rebalance().
            // slither-disable-next-line reentrancy-no-eth
            rewardsDelta = _harvestRewards();
            progress.step = IOllaCore.RebalanceStep.PullUnstaked;
        }

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.PullUnstaked) {
            // Pull any finalized exit funds. This is O(1) (single balance transfer), so no
            // gas gate needed. Exits still pending rollup finalization are non-blocking and
            // will be picked up in the next rebalance cycle.
            _pullUnstakedFunds();
            progress.step = IOllaCore.RebalanceStep.FinalizeWithdrawals;
        }

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.FinalizeWithdrawals) {
            uint256 withdrawalSnapshotEndId = _rebalanceWithdrawalSnapshotEndId;
            // slither-disable-next-line incorrect-equality
            if (withdrawalSnapshotEndId == 0) {
                withdrawalSnapshotEndId = vaultRef.nextWithdrawalRequestId();
                _rebalanceWithdrawalSnapshotEndId = withdrawalSnapshotEndId;
            }
            if (!_hasGasForStep()) {
                _rebalanceProgress = progress;
                return (rewardsDelta, 0, 0, vaultRef.bufferedAssets());
            }
            finalizedAmount = _finalizeWithdrawals(withdrawalSnapshotEndId);
            uint256 nextUnfinalized = vaultRef.nextUnfinalizedWithdrawalRequestId();
            // slither-disable-next-line incorrect-equality,timestamp
            if (nextUnfinalized >= withdrawalSnapshotEndId || vaultRef.bufferedAssets() == 0 || finalizedAmount == 0) {
                progress.step = IOllaCore.RebalanceStep.InitiateUnstake;
            } else {
                _rebalanceProgress = progress;
                return (rewardsDelta, finalizedAmount, 0, vaultRef.bufferedAssets());
            }
        }

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.InitiateUnstake) {
            {
                uint256 requiredBuffer = vaultRef.pendingWithdrawalAssets();
                progress.unstakeRemaining = _computeUnstakeRemaining(requiredBuffer);
            }
            // slither-disable-next-line incorrect-equality,timestamp
            if (progress.unstakeRemaining == 0) {
                progress.step = IOllaCore.RebalanceStep.StakeSurplus;
            } else {
                if (!_hasGasForStep()) {
                    _rebalanceProgress = progress;
                    return (rewardsDelta, finalizedAmount, 0, vaultRef.bufferedAssets());
                }
                uint256 initiated = _initiateUnstake(progress.unstakeRemaining);
                if (initiated >= progress.unstakeRemaining) {
                    progress.unstakeRemaining = 0;
                } else {
                    progress.unstakeRemaining -= initiated;
                }

                // slither-disable-next-line timestamp
                if (progress.unstakeRemaining != 0) {
                    // slither-disable-next-line incorrect-equality
                    if (initiated == 0 && _modules.stakingManager.getActivatedAttesterCount() == 0) {
                        progress.unstakeRemaining = 0;
                        progress.step = IOllaCore.RebalanceStep.StakeSurplus;
                    } else {
                        _rebalanceProgress = progress;
                        return (rewardsDelta, finalizedAmount, 0, vaultRef.bufferedAssets());
                    }
                }
                progress.step = IOllaCore.RebalanceStep.StakeSurplus;
            }
        }

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.StakeSurplus) {
            uint256 requiredBuffer = vaultRef.pendingWithdrawalAssets();
            uint256 freshStakeRemaining = _computeStakeRemaining(requiredBuffer);
            // slither-disable-next-line incorrect-equality,timestamp
            if (progress.stakeRemaining == 0) {
                progress.stakeRemaining = freshStakeRemaining;
            } else if (progress.stakeRemaining > freshStakeRemaining) {
                progress.stakeRemaining = freshStakeRemaining;
            }

            // slither-disable-next-line incorrect-equality,timestamp
            if (progress.stakeRemaining == 0) {
                progress.step = IOllaCore.RebalanceStep.Done;
            } else if (!_modules.stakingManager.canStake(progress.stakeRemaining)) {
                // Resuming a partial stake but no keys or amount below threshold.
                progress.stakeRemaining = 0;
                progress.step = IOllaCore.RebalanceStep.Done;
            }
            // slither-disable-next-line incorrect-equality,timestamp
            if (progress.step == IOllaCore.RebalanceStep.StakeSurplus) {
                if (!_hasGasForStep()) {
                    _rebalanceProgress = progress;
                    return (rewardsDelta, finalizedAmount, 0, vaultRef.bufferedAssets());
                }

                stakedAmount = _stakeSurplus(progress.stakeRemaining);
                progress.stakeRemaining -= stakedAmount;

                // slither-disable-next-line timestamp
                if (progress.stakeRemaining != 0) {
                    // slither-disable-next-line incorrect-equality
                    if (stakedAmount == 0) {
                        progress.stakeRemaining = 0;
                        progress.step = IOllaCore.RebalanceStep.Done;
                    } else {
                        _rebalanceProgress = progress;
                        return (rewardsDelta, finalizedAmount, stakedAmount, vaultRef.bufferedAssets());
                    }
                }
                progress.step = IOllaCore.RebalanceStep.Done;
            }
        }

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.Done) {
            progress.stakeRemaining = 0;
            progress.unstakeRemaining = 0;
            _rebalanceWithdrawalSnapshotEndId = 0;
            // slither-disable-next-line incorrect-equality,timestamp
            if (stakedAmount == 0 && finalizedAmount == 0 && rewardsDelta == 0) {
                _rebalanceIdleBuffer = vaultRef.bufferedAssets();
            } else {
                _rebalanceIdleBuffer = 0;
            }
        }

        _rebalanceProgress = progress;
        resultingBuffer = vaultRef.bufferedAssets();

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.Done) {
            emit Rebalanced(rewardsDelta, finalizedAmount, stakedAmount, resultingBuffer);
        }

        if (_rebalanceCompletionSatisfied(progress)) {
            // slither-disable-next-line timestamp
            lastRebalanceTimestamp = SafeCast.toUint48(block.timestamp);
            _updateAccountingInternal();
        }

        return (rewardsDelta, finalizedAmount, stakedAmount, resultingBuffer);
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end cyclomatic-complexity
    // slither-disable-end incorrect-equality,timestamp
    // solhint-enable function-max-lines

    // slither-disable-start pess-multiple-storage-read
    // Accounting reads multiple storage structs atomically; caching would complicate correctness.
    // solhint-disable function-max-lines
    /// @notice Permissionless accounting update hook.
    function updateAccounting() external override whenNotPaused whenRebalanceDone nonReentrant {
        _updateAccountingInternal();
    }

    // solhint-enable function-max-lines
    // slither-disable-end pess-multiple-storage-read

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaCore
    function asset() external view override returns (address) {
        return address(_modules.asset);
    }

    /// @inheritdoc IOllaCore
    function vault() external view override returns (address) {
        return _modules.vault;
    }

    /// @inheritdoc IOllaCore
    function stAztec() external view override returns (address) {
        return address(_modules.stAztec);
    }

    /// @inheritdoc IOllaCore
    function stakingManager() external view override returns (address) {
        return address(_modules.stakingManager);
    }

    /// @inheritdoc IOllaCore
    function rewardsAccumulator() external view override returns (address) {
        return address(_modules.rewardsAccumulator);
    }

    /// @inheritdoc IOllaCore
    function safetyModule() external view override returns (address) {
        return _modules.safetyModule;
    }

    /// @inheritdoc IOllaCore
    function latestReport() external view override returns (IOllaCore.LatestReport memory) {
        return _latestReport;
    }

    /// @inheritdoc IOllaCore
    function rebalanceProgress() external view override returns (IOllaCore.RebalanceProgress memory) {
        return IOllaCore.RebalanceProgress({
            step: _rebalanceProgress.step,
            stakeRemaining: _rebalanceProgress.stakeRemaining,
            unstakeRemaining: _rebalanceProgress.unstakeRemaining
        });
    }

    /// @inheritdoc IOllaCore
    function flowCounters() external view override returns (IOllaCore.FlowCounters memory) {
        IOllaCore.FlowCounters memory flows = _flowCounters;
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        flows.cumulativeDeposits = vaultRef.cumulativeDeposits();
        flows.cumulativeWithdrawals = vaultRef.cumulativeWithdrawals();
        flows.cumulativeSlashingAdjustments = vaultRef.cumulativeSlashingAdjustments();
        return flows;
    }

    /// @inheritdoc IOllaCore
    /// @dev Returns a freshly-assembled snapshot derived from live module reads (StakingManager,
    ///      RewardsAccumulator). The `cumulativeRewards` field is a genuine ledger and is still
    ///      sourced from storage. Staticcall-safe for indexers/UI.
    function accountingState() external view override returns (IOllaCore.AccountingState memory) {
        return _liveAccountingState();
    }

    /// @inheritdoc IOllaCore
    function exchangeRate() external view override returns (uint256) {
        return _exchangeRate();
    }

    /// @inheritdoc IOllaCore
    function withdrawalRate() external view override returns (uint256) {
        return _withdrawalRate(IOllaVault(_modules.vault));
    }

    /// @inheritdoc IOllaCore
    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc IOllaCore
    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        return _convertToAssets(shares);
    }

    /// @inheritdoc IOllaCore
    function convertToAssetsCeil(uint256 shares) external view override returns (uint256 assets) {
        return shares.mulDiv(
            totalAssets() + _VIRTUAL_OFFSET, _modules.stAztec.totalSupply() + _VIRTUAL_OFFSET, Math.Rounding.Ceil
        );
    }

    function renounceOwnership() public view override onlyOwner {
        revert("renouncing ownership not allowed");
    }

    /// @inheritdoc IOllaCore
    /// @dev Includes exit fee revenue held in `_bufferedAssets`. For staking yield only
    ///      (excluding exit fee redistribution), use `_latestReport.grossRewards`.
    function totalAssets() public view override returns (uint256) {
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        IOllaCore.AccountingState memory buckets = _liveAccountingState();
        uint256 bufferedAssets = vaultRef.bufferedAssets();
        uint256 pendingAssets = _pricingPendingAssets(vaultRef, buckets, bufferedAssets);
        return _computeTotalAssets(buckets, bufferedAssets, pendingAssets);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Runs the full accounting update pipeline: reads module state, computes fees, and emits reports.
    function _updateAccountingInternal() internal {
        ISafetyModule safetyModuleRef = ISafetyModule(_modules.safetyModule);
        // slither-disable-start reentrancy-no-eth
        // slither-disable-start reentrancy-benign
        // slither-disable-start reentrancy-events
        // All external calls target trusted protocol contracts (SafetyModule, Vault, StakingManager);
        // callers of this path are guarded by nonReentrant.
        safetyModuleRef.checkAccountingLiveness();

        (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows) = _getFlowsSnapshot();
        // Include the unrecorded RewardsAccumulator balance: out-of-band `claimSequencerRewards`
        // calls move rollup-side rewards into the accumulator without updating `_cumulativeRewards`,
        // so omitting this term would understate the snapshot until the next harvest.
        uint256 currentRewards =
            _cumulativeRewards + _modules.stakingManager.getClaimableRewards() + _getRewardsAccumulatorBalance();

        _computeAndFinalizeAccounting(safetyModuleRef, flowsSnapshot, netFlows, currentRewards);
        // slither-disable-end reentrancy-events
        // slither-disable-end reentrancy-benign
        // slither-disable-end reentrancy-no-eth
    }

    // Called within nonReentrant rebalance(); StakingManager and RewardsAccumulator are trusted.
    /// @notice Harvests rewards from StakingManager, records the delta, and pulls accumulated funds to Vault.
    /// @return rewardsDelta The newly recorded rewards delta from the RewardsAccumulator.
    // slither-disable-next-line reentrancy-no-eth,pess-multiple-storage-read
    function _harvestRewards() internal returns (uint256 rewardsDelta) {
        // harvestRewards return value is unused; reward accounting is via recordBalance() below.
        // slither-disable-next-line unused-return
        _modules.stakingManager.harvestRewards();

        IRewardsAccumulator rewardsAccumulatorRef = _modules.rewardsAccumulator;
        // RewardsAccumulator.recordBalance() is trusted; only updates internal accounting.
        // slither-disable-next-line reentrancy-benign
        rewardsDelta = rewardsAccumulatorRef.recordBalance();
        if (rewardsDelta != 0) {
            _cumulativeRewards += rewardsDelta;
        }
        emit RewardsDelta(rewardsDelta);

        _pullRewardsAccumulatorFunds();

        return rewardsDelta;
    }

    /// @notice Withdraws all RewardsAccumulator funds and forwards them to the Vault as buffered assets.
    /// @return pulledAmount The amount of rewards pulled from the accumulator.
    function _pullRewardsAccumulatorFunds() internal returns (uint256 pulledAmount) {
        CoreModules memory modules = _modules;
        IRewardsAccumulator rewardsAccumulatorRef = modules.rewardsAccumulator;
        uint256 rewardsAccumulatorBalance = rewardsAccumulatorRef.balance();

        // Zero-balance short circuit; not a timestamp concern.
        // slither-disable-next-line timestamp,incorrect-equality
        if (rewardsAccumulatorBalance == 0) return 0;

        IOllaVault vaultRef = IOllaVault(modules.vault);

        // Trusted RewardsAccumulator; only transfers tokens to this contract.
        // slither-disable-next-line reentrancy-benign
        rewardsAccumulatorRef.withdrawToCore();
        // Forward received funds to Vault
        modules.asset.safeTransfer(address(vaultRef), rewardsAccumulatorBalance);
        vaultRef.receiveUnstaked(rewardsAccumulatorBalance);

        emit RewardsAccumulatorFundsPulled(rewardsAccumulatorBalance);
        return rewardsAccumulatorBalance;
    }

    /// @notice Claims exited unstaked funds from StakingManager and forwards them to the Vault.
    /// @return receivedAmount The actual token amount received.
    function _pullUnstakedFunds() internal returns (uint256 receivedAmount) {
        IOllaCore.CoreModules memory modules = _modules;
        IERC20 assetRef = modules.asset;
        uint256 balanceBefore = assetRef.balanceOf(address(this));

        // Trusted StakingManager; transfers unstaked funds to this contract.
        // slither-disable-next-line reentrancy-benign,unused-return
        (receivedAmount,) = modules.stakingManager.getUnstakedFunds();

        uint256 balanceAfter = assetRef.balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;

        if (receivedAmount != 0 && receivedAmount != actualReceived) {
            revert OllaCore__UnstakedFundsMismatch(receivedAmount, actualReceived);
        }

        // Forward received funds to Vault
        if (actualReceived > 0) {
            IOllaVault vaultRef = IOllaVault(modules.vault);
            assetRef.safeTransfer(address(vaultRef), actualReceived);
            vaultRef.receiveUnstaked(actualReceived);
            emit UnstakedFundsClaimed(actualReceived);
        }

        return actualReceived;
    }

    /// @notice Instructs the Vault to finalize pending withdrawal requests using available buffered assets.
    /// @param maxRequestId The exclusive request id upper bound for this finalization pass.
    /// @return finalizedAmount The total assets used for finalization.
    function _finalizeWithdrawals(uint256 maxRequestId) internal returns (uint256 finalizedAmount) {
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        uint256 available = vaultRef.bufferedAssets();

        // Zero-balance short circuit; not a timestamp concern.
        // slither-disable-next-line timestamp,incorrect-equality
        if (available == 0) return 0;

        uint256 queued = vaultRef.pendingWithdrawalAssets();
        uint256 total = totalAssets();

        // Trusted SafetyModule; may trigger circuit breaker but holds no funds.
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
        ISafetyModule(_modules.safetyModule).checkQueueRatio(queued, total);

        // Zero-queue short circuit; not a timestamp concern.
        // slither-disable-next-line timestamp,incorrect-equality
        if (queued == 0) return 0;

        uint256 initialAvailable = available;
        // slither-disable-start calls-loop
        // Trusted Vault/StAztec reads and Vault finalization are intentionally repeated so each
        // queue head settles against a rate recomputed after the prior request changes pending state.
        while (vaultRef.nextUnfinalizedWithdrawalRequestId() < maxRequestId && available > 0 && _hasGasForStep()) {
            uint256 nextRequestId = vaultRef.nextUnfinalizedWithdrawalRequestId();
            // Finalize only the current queue head so the next iteration's gross rate reflects
            // the just-finalized request's pending-share and buffered-asset removal.
            uint256 requestUpperBound = nextRequestId + 1;

            // Trusted Vault; finalizes pending withdrawal queue entries.
            // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
            (uint256 amount, uint256 count) =
                vaultRef.finalizeWithdrawals(available, _withdrawalRate(vaultRef), requestUpperBound);

            // slither-disable-next-line timestamp
            if (count < 1) break;

            finalizedAmount += amount;
            available = vaultRef.bufferedAssets();

            if (vaultRef.pendingWithdrawalAssets() < 1) break;
        }
        // slither-disable-end calls-loop

        emit WithdrawalFinalized(initialAvailable, finalizedAmount);
        return finalizedAmount;
    }

    // slither-disable-start pess-multiple-storage-read,reentrancy-benign
    // Benign reentrancy: calls go to trusted Vault/StakingManager within nonReentrant rebalance().
    // Multiple storage reads across _modules fields are required for the stake flow.
    /// @notice Pulls buffered assets from Vault and stakes them via StakingManager.
    /// @dev Returns excess assets to Vault if StakingManager accepts less than requested.
    /// @param stakeable The maximum amount of assets to stake.
    /// @return totalStaked The actual amount staked.
    function _stakeSurplus(uint256 stakeable) internal returns (uint256 totalStaked) {
        // Zero-stakeable short circuit.
        // slither-disable-next-line incorrect-equality,timestamp
        if (stakeable == 0) return 0;

        IOllaVault vaultRef = IOllaVault(_modules.vault);
        IStakingManager stakingManagerRef = _modules.stakingManager;

        IERC20 assetRef = _modules.asset;

        // Pull assets from Vault to Core, then approve StakingManager to pull from Core.
        // This preserves the StakingManager's existing `safeTransferFrom(core, ...)` pattern.
        vaultRef.transferToCore(stakeable);
        assetRef.forceApprove(address(stakingManagerRef), stakeable);

        // Trusted StakingManager; pulls pre-approved assets for staking.
        // slither-disable-next-line reentrancy-no-eth
        try stakingManagerRef.stake(stakeable) returns (uint256 actualStaked) {
            // Sanity bound check; not a timestamp concern.
            // slither-disable-next-line timestamp
            if (actualStaked > stakeable) revert OllaCore__StakeFailed(actualStaked);
            totalStaked = actualStaked;
        } catch {
            // Stake failed entirely -- return all assets to Vault and clear the residual
            // allowance granted to StakingManager before the failed call.
            assetRef.forceApprove(address(stakingManagerRef), 0);
            assetRef.safeTransfer(address(vaultRef), stakeable);
            vaultRef.receiveUnstaked(stakeable);
            return 0;
        }

        // Return any excess (stakeable - actualStaked) to Vault and clear any residual
        // allowance left over from the partial-stake path.
        uint256 excess = stakeable - totalStaked;
        if (excess > 0) {
            assetRef.safeTransfer(address(vaultRef), excess);
            vaultRef.receiveUnstaked(excess);
        }
        assetRef.forceApprove(address(stakingManagerRef), 0);

        return totalStaked;
    }

    // slither-disable-end pess-multiple-storage-read,reentrancy-benign

    // slither-disable-start pess-unprotected-initialize
    // False positive: function name contains "initiate" but is not an initializer.
    /// @notice Requests StakingManager to begin unstaking a given amount, net of pending unstakes.
    /// @param requested The target amount to unstake.
    /// @return initiated The amount actually accepted for unstaking.
    function _initiateUnstake(uint256 requested) internal returns (uint256 initiated) {
        // Zero-requested short circuit.
        // slither-disable-next-line incorrect-equality,timestamp
        if (requested == 0) return 0;

        IStakingManager stakingManagerRef = _modules.stakingManager;
        uint256 pendingUnstakes = stakingManagerRef.pendingUnstakes();

        // Trusted StakingManager; initiates exit messages for attesters.
        // slither-disable-next-line reentrancy-no-eth
        initiated = stakingManagerRef.unstake(requested);
        // Positive-amount guard; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (initiated > 0) {
            emit UnstakeInitiated(requested + pendingUnstakes, initiated);
        }
        return initiated;
    }

    // slither-disable-end pess-unprotected-initialize

    /// @notice Payout protocol fees through minting shares via Vault.
    /// @param grossAssetRewards The gross asset rewards to base fees on.
    /// @return ollaProtocolFeeAssets The protocol fee amount in assets.
    /// @return treasuryShares The shares minted to treasury.
    /// @return providerShares The shares minted to the provider.
    function _payoutOllaProtocolFees(uint256 grossAssetRewards)
        internal
        returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        // Zero-value short circuits; no fees when rewards/fee/assets are zero.
        // slither-disable-next-line incorrect-equality,timestamp
        if (grossAssetRewards == 0 || protocolFeeBP == 0 || totalAssets() == 0) {
            return (0, 0, 0);
        }
        (ollaProtocolFeeAssets, treasuryShares, providerShares) = _calculateProtocolFees(grossAssetRewards);
        emit OllaProtocolFeesPaid(ollaProtocolFeeAssets, treasuryShares, providerShares);

        address treasuryAddr = _treasury();
        address providerRewardsRecipient = _modules.stakingManager.getProviderConfig().rewardsRecipient;

        // Vault mints the shares on Core's instruction
        IOllaVault(_modules.vault).mintFees(treasuryAddr, treasuryShares, providerRewardsRecipient, providerShares);

        return (ollaProtocolFeeAssets, treasuryShares, providerShares);
    }

    // Writes to _latestReport and _flowCounters storage structs atomically.
    /// @notice Persists accounting report and flow counter snapshots to storage.
    // slither-disable-next-line pess-multiple-storage-read
    function _updateReportingSnapshots(
        uint256 total,
        uint256 rate,
        uint256 grossRewards,
        int256 netFlows,
        IOllaCore.FlowCounters memory flowsSnapshot,
        uint256 rewardsSnapshot
    ) internal {
        IOllaCore.LatestReport storage report = _latestReport;
        report.totalAssets = total;
        report.exchangeRate = rate;
        report.grossRewards = grossRewards;
        report.netFlows = netFlows;
        report.rewardsSnapshot = rewardsSnapshot;
        // Snapshot timestamp for accounting report; miner manipulation (~15s) is negligible.
        // slither-disable-next-line timestamp
        report.timestamp = block.timestamp;

        IOllaCore.FlowCounters storage flows = _flowCounters;
        flows.latestReportCumulativeDeposits = flowsSnapshot.cumulativeDeposits;
        flows.latestReportCumulativeWithdrawals = flowsSnapshot.cumulativeWithdrawals;
        flows.latestReportCumulativeSlashingAdjustments = flowsSnapshot.cumulativeSlashingAdjustments;
    }

    /// @notice Computes updated accounting outputs, runs safety checks, and persists the final report.
    /// @param safetyModuleRef The SafetyModule instance for rate-drop and queue-ratio checks.
    /// @param flowsSnapshot The flow counters snapshot for the current accounting cycle.
    /// @param netFlows The signed net deposit/withdrawal flows since the last report.
    /// @param currentRewards The cumulative rewards value used for the report snapshot.
    function _computeAndFinalizeAccounting(
        ISafetyModule safetyModuleRef,
        IOllaCore.FlowCounters memory flowsSnapshot,
        int256 netFlows,
        uint256 currentRewards
    ) internal {
        (uint256 oldTotalAssets, uint256 oldRate) = _getLatestReport();
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        uint256 pendingWithdrawals = vaultRef.pendingWithdrawalAssets();
        // Emit AttestersStateRead BEFORE `_updateReportingSnapshots` advances
        // `_latestReport.rewardsSnapshot`, otherwise rewardsDelta would be zero.
        // `block.timestamp` matches `_latestReport.timestamp` set later in this call.
        // slither-disable-next-line timestamp
        {
            IOllaCore.AccountingState memory attesterSnapshot = _liveAccountingState();
            emit AttestersStateRead(attesterSnapshot.rewardsDelta, attesterSnapshot.slashingDelta, block.timestamp);
        }
        // _computeAccountingOutputs calls trusted Vault and pays fees via trusted mint path.
        // slither-disable-next-line reentrancy-no-eth
        // slither-disable-next-line reentrancy-benign
        (
            uint256 newTotalAssets,
            uint256 grossRewards,
            uint256 protocolFeeAssets,
            uint256 treasuryShares,
            uint256 providerShares,
            uint256 rate
        ) = _computeAccountingOutputs(oldTotalAssets, netFlows, pendingWithdrawals);

        // Trusted SafetyModule; may trigger circuit breaker but holds no funds.
        // slither-disable-next-line reentrancy-no-eth
        safetyModuleRef.checkQueueRatio(pendingWithdrawals, totalAssets());
        _validateRateDrop(safetyModuleRef, oldRate, rate);
        _updateReportingSnapshots(newTotalAssets, rate, grossRewards, netFlows, flowsSnapshot, currentRewards);
        _updateAccountingTimestamp(safetyModuleRef);
        _emitAccountingReport(
            newTotalAssets, rate, grossRewards, netFlows, protocolFeeAssets, treasuryShares, providerShares
        );
    }

    /// @notice Derives totalAssets, gross rewards, protocol fees, and the new exchange rate.
    /// @param oldTotalAssets The previous totalAssets from the last report.
    /// @param netFlows The signed net deposit/withdrawal flows since the last report.
    /// @param pendingWithdrawals The current pending withdrawal asset amount.
    /// @return newTotalAssets The updated total assets value.
    /// @return grossRewards The gross rewards earned this period.
    /// @return protocolFeeAssets The protocol fee amount in assets.
    /// @return treasuryShares The shares minted to treasury.
    /// @return providerShares The shares minted to the provider.
    /// @return rate The new exchange rate.
    function _computeAccountingOutputs(uint256 oldTotalAssets, int256 netFlows, uint256 pendingWithdrawals)
        internal
        returns (
            uint256 newTotalAssets,
            uint256 grossRewards,
            uint256 protocolFeeAssets,
            uint256 treasuryShares,
            uint256 providerShares,
            uint256 rate
        )
    {
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        newTotalAssets = _computeTotalAssets(_liveAccountingState(), vaultRef.bufferedAssets(), pendingWithdrawals);
        int256 grossRewardsSigned;
        (grossRewards, grossRewardsSigned) = _computeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        // Signed comparison for negative rewards detection; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (grossRewardsSigned < 0) {
            emit NegativeRewardsPeriod(grossRewardsSigned);
        }
        (protocolFeeAssets, treasuryShares, providerShares) = _payoutOllaProtocolFees(grossRewards);
        rate = _exchangeRate();
        return (newTotalAssets, grossRewards, protocolFeeAssets, treasuryShares, providerShares, rate);
    }

    /// @notice Delegates exchange-rate drop validation to the SafetyModule circuit breaker.
    /// @param safetyModuleRef The SafetyModule instance to check against.
    /// @param oldRate The previous exchange rate.
    /// @param rate The new exchange rate.
    function _validateRateDrop(ISafetyModule safetyModuleRef, uint256 oldRate, uint256 rate) internal {
        safetyModuleRef.checkRateDrop(oldRate, rate);
    }

    /// @notice Records the current block timestamp in the SafetyModule for liveness tracking.
    /// @param safetyModuleRef The SafetyModule instance to update.
    function _updateAccountingTimestamp(ISafetyModule safetyModuleRef) internal {
        // Recording the current timestamp is intentional; miner manipulation is negligible here.
        // slither-disable-next-line timestamp
        safetyModuleRef.setLatestAccountingTimestamp(block.timestamp);
    }

    /// @notice Emits the AccountingUpdated event for the current accounting cycle.
    /// @dev AttestersStateRead is emitted by `_computeAndFinalizeAccounting` using the pre-snapshot
    ///      rewardsDelta/slashingDelta (captured before `_updateReportingSnapshots` runs).
    /// @param newTotalAssets The updated total assets value.
    /// @param rate The new exchange rate.
    /// @param grossRewards The gross rewards earned this period.
    /// @param netFlows The signed net deposit/withdrawal flows.
    /// @param protocolFeeAssets The protocol fee amount in assets.
    /// @param treasuryShares The shares minted to treasury.
    /// @param providerShares The shares minted to the provider.
    function _emitAccountingReport(
        uint256 newTotalAssets,
        uint256 rate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares
    ) internal {
        emit AccountingUpdated(
            newTotalAssets,
            rate,
            grossRewards,
            netFlows,
            protocolFeeAssets,
            treasuryShares,
            providerShares,
            _latestReport.timestamp
        );
    }

    /// @notice Assembles an `AccountingState` snapshot from live module reads.
    /// @dev Authoritative source of accounting data for `totalAssets()`, `_withdrawalRate()`, and the
    ///      external `accountingState()` getter. Every field except `cumulativeRewards` is derived at
    ///      call time from the owning module -- `stakedPrincipal` and `slashingDelta` from
    ///      `StakingManager`, `claimableRewards` from the rollup via `StakingManager`, and
    ///      `rewardsAccumulatorBalance` from `RewardsAccumulator`. `cumulativeRewards` is a
    ///      protocol-internal ledger maintained in storage and copied through. `rewardsDelta` is
    ///      derived relative to `_latestReport.rewardsSnapshot` so the snapshot remains meaningful to
    ///      indexers between accounting reports. Because all reads occur inside a single staticcall,
    ///      callers receive a snapshot consistent as of the containing block.
    ///
    ///      Failure policy: if any underlying external call reverts, the revert propagates --
    ///      this is intentional (strict-propagation policy). Halting pricing-dependent
    ///      operations during dependency failure is preferable to serving stale rates. The
    ///      external `accountingState()` getter inherits this behavior; integrations that
    ///      need best-effort snapshots should handle reverts at the call site.
    /// @return snapshot A freshly-assembled AccountingState populated from authoritative sources.
    function _liveAccountingState() internal view returns (IOllaCore.AccountingState memory snapshot) {
        IOllaCore.CoreModules memory modules = _modules;
        uint256 cumulativeRewards = _cumulativeRewards;
        uint256 claimableRewards = modules.stakingManager.getClaimableRewards();
        uint256 rewardsAccumulatorBalance = modules.rewardsAccumulator.balance();

        uint256 latestReportRewards = _latestReport.rewardsSnapshot;
        // See `_updateAccountingInternal`: include unrecorded RewardsAccumulator balance so the
        // delta does not collapse when an out-of-band `claimSequencerRewards` call shifts rewards
        // from `claimableRewards` into the accumulator.
        uint256 currentRewards = cumulativeRewards + claimableRewards + rewardsAccumulatorBalance;
        // Positive-delta guard; signed comparison is not a timestamp concern.
        // slither-disable-next-line timestamp
        uint256 rewardsDelta = currentRewards > latestReportRewards ? currentRewards - latestReportRewards : 0;

        snapshot = IOllaCore.AccountingState({
            stakedPrincipal: modules.stakingManager.totalStaked(),
            rewardsAccumulatorBalance: rewardsAccumulatorBalance,
            claimableRewards: claimableRewards,
            rewardsDelta: rewardsDelta,
            slashingDelta: modules.stakingManager.getSlashingDelta(),
            cumulativeRewards: cumulativeRewards
        });
        return snapshot;
    }

    /// @notice Returns true if enough gas remains to execute another rebalance step.
    /// @return True if gasleft exceeds the rebalance gas threshold.
    function _hasGasForStep() internal view returns (bool) {
        return gasleft() > rebalanceGasThreshold;
    }

    // Reads multiple module state to determine if rebalance work exists; zero-checks are intentional.
    /// @notice Checks whether any actionable work exists across rewards, unstakes, or withdrawal queue.
    /// @dev This function checks only protocol-internal state (e.g. `_pendingClaimAmount`) and does NOT
    ///      query the rollup for unclaimed exits directly. Rollup state must be synced beforehand via
    ///      the permissionless `refreshAttesterState()` call. This is intentional: on-demand rollup
    ///      queries would require iterating all attesters with cross-contract calls, creating unbounded
    ///      gas costs. Staleness between `refreshAttesterState()` calls is an accepted design trade-off.
    // slither-disable-next-line timestamp,pess-multiple-storage-read
    function _hasRebalanceWorkAvailable() internal view returns (bool) {
        uint256 rewardsAccumulatorBalance = _getRewardsAccumulatorBalance();
        if (rewardsAccumulatorBalance > REWARDS_ACCUMULATOR_DUST_THRESHOLD) return true;

        if (_modules.stakingManager.getClaimableRewards() > 0) return true;

        if (_modules.stakingManager.hasFinalizedUnstakes()) return true;

        IOllaVault vaultRef = IOllaVault(_modules.vault);
        uint256 pendingWithdrawals = vaultRef.pendingWithdrawalAssets();
        uint256 currentBuffer = vaultRef.bufferedAssets();
        if (pendingWithdrawals > 0 && currentBuffer > 0) return true;

        // Surplus buffer that can actually be staked (keys available + amount >= threshold).
        if (currentBuffer > 0 && _modules.stakingManager.canStake(currentBuffer)) return true;

        return false;
    }

    /// @notice Calculates how much more needs to be unstaked to meet the required buffer, net of incoming funds.
    /// @param requiredBuffer The total buffer needed to cover withdrawals and target.
    /// @return remaining The additional amount to unstake.
    function _computeUnstakeRemaining(uint256 requiredBuffer) internal view returns (uint256 remaining) {
        uint256 currentBuffer = IOllaVault(_modules.vault).bufferedAssets();
        // Buffer sufficiency check; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (requiredBuffer < currentBuffer) return 0;
        uint256 amountToUnstake = requiredBuffer - currentBuffer;
        uint256 pendingIncoming =
            _modules.stakingManager.pendingUnstakes() + _modules.stakingManager.claimableUnstakedFunds();
        // Pending unstakes already cover the deficit; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (pendingIncoming > amountToUnstake) return 0;
        remaining = amountToUnstake - pendingIncoming;
        return remaining;
    }

    /// @notice Calculates surplus buffer available for staking above the required buffer.
    /// @param requiredBuffer The total buffer needed to cover withdrawals and target.
    /// @return remaining The surplus amount available to stake.
    function _computeStakeRemaining(uint256 requiredBuffer) internal view returns (uint256 remaining) {
        uint256 currentBuffer = IOllaVault(_modules.vault).bufferedAssets();
        // Insufficient buffer to stake; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (currentBuffer < requiredBuffer) return 0;
        remaining = currentBuffer - requiredBuffer;
        return remaining;
    }

    /// @notice Reads cumulative deposit/withdrawal counters from the Vault and computes net flows since last report.
    /// @return flowsSnapshot The current flow counters snapshot.
    /// @return netFlows The signed net deposit/withdrawal flows since the last report.
    function _getFlowsSnapshot() internal view returns (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows) {
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        flowsSnapshot = IOllaCore.FlowCounters({
            cumulativeDeposits: vaultRef.cumulativeDeposits(),
            cumulativeWithdrawals: vaultRef.cumulativeWithdrawals(),
            cumulativeSlashingAdjustments: vaultRef.cumulativeSlashingAdjustments(),
            latestReportCumulativeDeposits: _flowCounters.latestReportCumulativeDeposits,
            latestReportCumulativeWithdrawals: _flowCounters.latestReportCumulativeWithdrawals,
            latestReportCumulativeSlashingAdjustments: _flowCounters.latestReportCumulativeSlashingAdjustments
        });
        (netFlows,,) = _computeNetFlows(flowsSnapshot);
        return (flowsSnapshot, netFlows);
    }

    /// @notice Returns the totalAssets and exchangeRate from the last accounting report.
    /// @return reportedTotalAssets The total assets from the last report.
    /// @return reportedExchangeRate The exchange rate from the last report.
    function _getLatestReport() internal view returns (uint256 reportedTotalAssets, uint256 reportedExchangeRate) {
        IOllaCore.LatestReport memory report = _latestReport;
        return (report.totalAssets, report.exchangeRate);
    }

    /// @notice Returns the current token balance held by the RewardsAccumulator.
    /// @return rewardsAccumulatorBalance The token balance of the RewardsAccumulator.
    function _getRewardsAccumulatorBalance() internal view returns (uint256 rewardsAccumulatorBalance) {
        return IRewardsAccumulator(_modules.rewardsAccumulator).balance();
    }

    /// @notice Calculates protocol fee in assets, then splits into treasury and provider share amounts.
    /// @param grossAssetRewards The gross asset rewards to base fees on.
    /// @return ollaProtocolFeeAssets The protocol fee amount in assets.
    /// @return treasuryShares The shares allocated to the treasury.
    /// @return providerShares The shares allocated to the provider.
    function _calculateProtocolFees(uint256 grossAssetRewards)
        internal
        view
        returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        ollaProtocolFeeAssets = grossAssetRewards * protocolFeeBP / BP_DIVISOR;

        uint256 protocolSharesTotal = _convertToShares(ollaProtocolFeeAssets, Math.Rounding.Floor);

        treasuryShares = protocolSharesTotal * treasuryFeeSplitBP / BP_DIVISOR;
        providerShares = protocolSharesTotal - treasuryShares;

        return (ollaProtocolFeeAssets, treasuryShares, providerShares);
    }

    /// @dev Core is the pricing authority because it owns totalAssets() (assembled live via `_liveAccountingState`).
    ///      The Vault delegates pricing to Core via cross-contract calls to avoid circular dependencies.
    ///      Rate reflects the current state of the owning modules (StakingManager, RewardsAccumulator, Vault)
    ///      read at call time — no intermediate caching. `updateAccounting()` only advances the reporting
    ///      snapshot (`_latestReport`); it does not gate pricing reads.
    function _exchangeRate() internal view returns (uint256) {
        return (totalAssets() + _VIRTUAL_OFFSET)
        .mulDiv(_EXCHANGE_RATE_SCALE, _modules.stAztec.totalSupply() + _VIRTUAL_OFFSET, Math.Rounding.Floor);
    }

    /// @notice Computes pending withdrawal assets to subtract for live share pricing.
    /// @dev Uses the slash-adjusted gross-rate value and caps it at locked pending assets. This prevents
    ///      double-discounting pending withdrawals after slashing while preserving raw queue liabilities
    ///      until finalization.
    /// @param vaultRef The vault reference.
    /// @param buckets The live accounting state buckets.
    /// @param bufferedAssets The current buffered assets.
    /// @return The pending asset amount to subtract for pricing.
    function _pricingPendingAssets(
        IOllaVault vaultRef,
        IOllaCore.AccountingState memory buckets,
        uint256 bufferedAssets
    ) internal view returns (uint256) {
        uint256 pendingAssets = vaultRef.pendingWithdrawalAssets();
        if (pendingAssets == 0) return 0;

        uint256 pendingShares = vaultRef.pendingWithdrawalShares();
        if (pendingShares == 0) return pendingAssets;

        uint256 virtualOffset = _VIRTUAL_OFFSET;
        uint256 grossAssets = _computeTotalAssets(buckets, bufferedAssets, 0);
        uint256 liveSupply = _modules.stAztec.totalSupply();
        uint256 currentRate = (grossAssets + virtualOffset)
        .mulDiv(_EXCHANGE_RATE_SCALE, liveSupply + pendingShares + virtualOffset, Math.Rounding.Floor);

        // Price live shares only against `liveSupply`. The virtual offset is an anti-donation
        // constant, not a real share, so it must not accrue rate exposure here (otherwise the
        // residual `V * (rate - 1)` biases the pending-asset discount).
        uint256 pricedLiveAssets = currentRate.mulDiv(liveSupply, _EXCHANGE_RATE_SCALE, Math.Rounding.Ceil);
        // Pure arithmetic guard; no block timestamp dependency.
        // slither-disable-next-line timestamp
        if (pricedLiveAssets < virtualOffset + 1) return Math.min(grossAssets, pendingAssets);

        // Pure arithmetic guard; no block timestamp dependency.
        // slither-disable-next-line timestamp
        if (pricedLiveAssets > grossAssets - 1) return 0;

        uint256 adjustedPendingAssets = grossAssets - pricedLiveAssets;

        return Math.min(adjustedPendingAssets, pendingAssets);
    }

    /// @notice Computes the exchange rate for withdrawal queue finalization.
    /// @dev Uses gross total assets (before subtracting pending withdrawals) and gross total supply
    ///      (including shares burned for pending requests). Pending withdrawal shares remain in this
    ///      gross supply until finalized, so they continue to share pro-rata in both slashing losses
    ///      and accrued rewards. Rewards can therefore restore the current rate after a slash and
    ///      reduce or eliminate the queue adjustment, but finalized payouts remain capped at each
    ///      request's locked `assetsExpected`.
    /// @param vaultRef The vault reference.
    /// @return The withdrawal-safe exchange rate.
    function _withdrawalRate(IOllaVault vaultRef) internal view returns (uint256) {
        // slither-disable-start calls-loop
        // This function is intentionally called during per-request finalization; the Vault and
        // stAztec are trusted protocol modules and must be reread after each queue head settles.
        uint256 buffered = vaultRef.bufferedAssets();
        uint256 grossAssets = _computeTotalAssets(_liveAccountingState(), buffered, 0);
        uint256 grossSupply = _modules.stAztec.totalSupply() + vaultRef.pendingWithdrawalShares();
        uint256 rate = (grossAssets + _VIRTUAL_OFFSET)
        .mulDiv(_EXCHANGE_RATE_SCALE, grossSupply + _VIRTUAL_OFFSET, Math.Rounding.Floor);
        // slither-disable-end calls-loop
        return rate;
    }

    /// @notice Converts a share amount to assets using floor rounding.
    /// @param shares The share amount to convert.
    /// @return The equivalent asset amount.
    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return shares.mulDiv(
            totalAssets() + _VIRTUAL_OFFSET, _modules.stAztec.totalSupply() + _VIRTUAL_OFFSET, Math.Rounding.Floor
        );
    }

    /// @notice Converts an asset amount to shares using the specified rounding direction.
    /// @param assets The asset amount to convert.
    /// @param rounding The rounding direction to apply.
    /// @return The equivalent share amount.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return
            assets.mulDiv(_modules.stAztec.totalSupply() + _VIRTUAL_OFFSET, totalAssets() + _VIRTUAL_OFFSET, rounding);
    }

    /// @notice Returns the treasury address from the OllaGovernance owner.
    /// @return The treasury address.
    function _treasury() internal view returns (address) {
        return IOllaGovernance(owner()).treasury();
    }

    /// @notice Authorizes a UUPS upgrade; reverts if newImplementation is zero.
    /// @param newImplementation The address of the new implementation contract.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert OllaCore__ZeroAddress("newImplementation");
    }

    /// @notice Returns true if the rebalance state machine has reached the Done step.
    /// @param progress The current rebalance progress state.
    /// @return True if the rebalance step is Done.
    function _rebalanceCompletionSatisfied(IOllaCore.RebalanceProgress memory progress) internal pure returns (bool) {
        // Enum equality check; not a timestamp concern.
        // slither-disable-next-line incorrect-equality,timestamp
        return progress.step == IOllaCore.RebalanceStep.Done;
    }

    /// @notice Validates all initialize() parameters for zero-address and range checks.
    /// @param asset_ The underlying asset token.
    /// @param stAztec_ The stAztec share token.
    /// @param stakingManager_ The staking manager contract.
    /// @param protocolFeeBP_ The initial protocol fee in basis points.
    /// @param treasuryFeeSplitBP_ The initial treasury fee split in basis points.
    /// @param governanceContract_ The governance contract address.
    /// @param rewardsAccumulator_ The rewards accumulator contract.
    /// @param safetyModule_ The safety module address.
    function _validateInitialParams(
        IERC20 asset_,
        IStAztec stAztec_,
        IStakingManager stakingManager_,
        uint256 protocolFeeBP_,
        uint256 treasuryFeeSplitBP_,
        address governanceContract_,
        IRewardsAccumulator rewardsAccumulator_,
        address safetyModule_
    ) internal pure {
        if (address(asset_) == address(0)) {
            revert OllaCore__ZeroAddress("asset_");
        }
        if (address(stAztec_) == address(0)) revert OllaCore__ZeroAddress("stAztec_");
        if (address(stakingManager_) == address(0)) revert OllaCore__ZeroAddress("stakingManager_");
        if (protocolFeeBP_ > MAX_PROTOCOL_FEE_BP) revert OllaCore__InvalidFeeBP(protocolFeeBP_);
        if (treasuryFeeSplitBP_ < MIN_TREASURY_SPLIT_BP || treasuryFeeSplitBP_ > MAX_TREASURY_SPLIT_BP) {
            revert OllaCore__InvalidSplitBP(treasuryFeeSplitBP_);
        }
        if (governanceContract_ == address(0)) revert OllaCore__ZeroAddress("governanceContract_");
        if (address(rewardsAccumulator_) == address(0)) revert OllaCore__ZeroAddress("rewardsAccumulator_");
        if (safetyModule_ == address(0)) revert OllaCore__ZeroAddress("safetyModule_");
    }

    /// @notice Computes signed net flows (deposits minus withdrawals) since the last report.
    /// @param flows The flow counters snapshot to compute from.
    /// @return netFlows The signed net deposit/withdrawal flows.
    /// @return netDeposits The net deposits since the last report.
    /// @return netWithdrawals The net withdrawals since the last report.
    function _computeNetFlows(IOllaCore.FlowCounters memory flows)
        internal
        pure
        returns (int256 netFlows, uint256 netDeposits, int256 netWithdrawals)
    {
        // Cumulative counter comparison; not a timestamp concern.
        // slither-disable-next-line timestamp
        netDeposits = flows.cumulativeDeposits > flows.latestReportCumulativeDeposits
            ? flows.cumulativeDeposits - flows.latestReportCumulativeDeposits
            : 0;
        // Cumulative counter comparison; not a timestamp concern.
        // slither-disable-next-line timestamp
        uint256 rawWithdrawals = flows.cumulativeWithdrawals > flows.latestReportCumulativeWithdrawals
            ? flows.cumulativeWithdrawals - flows.latestReportCumulativeWithdrawals
            : 0;
        // Cumulative counter comparison; not a timestamp concern.
        // slither-disable-next-line timestamp
        uint256 adjustmentsSinceReport = flows.cumulativeSlashingAdjustments
                > flows.latestReportCumulativeSlashingAdjustments
            ? flows.cumulativeSlashingAdjustments - flows.latestReportCumulativeSlashingAdjustments
            : 0;
        // Signed effective withdrawals: when slashing adjustments exceed user withdrawals in a
        // period, the excess flows through as negative netWithdrawals (positive contribution to
        // netFlows) instead of being silently dropped via an unsigned clamp. The clamp would
        // inflate gross rewards by exactly the dropped magnitude.
        netWithdrawals = SafeCast.toInt256(rawWithdrawals) - SafeCast.toInt256(adjustmentsSinceReport);
        netFlows = SafeCast.toInt256(netDeposits) - netWithdrawals;
        return (netFlows, netDeposits, netWithdrawals);
    }

    /// @notice Computes total assets from accounting buckets, buffered assets, and pending withdrawals.
    /// @param buckets The accounting state buckets.
    /// @param bufferedAssets The current buffered asset balance.
    /// @param pendingWithdrawals The current pending withdrawal asset amount.
    /// @return totalAssets_ The computed total assets value.
    function _computeTotalAssets(
        IOllaCore.AccountingState memory buckets,
        uint256 bufferedAssets,
        uint256 pendingWithdrawals
    ) internal pure returns (uint256 totalAssets_) {
        // stakedPrincipal is already net-of-slashing (StakingManager.totalStaked() returns the
        // actual staked amount after slashing reduces it)
        uint256 total =
            bufferedAssets + buckets.stakedPrincipal + buckets.rewardsAccumulatorBalance + buckets.claimableRewards;

        // Underflow guard; not a timestamp concern.
        // slither-disable-next-line timestamp
        totalAssets_ = pendingWithdrawals >= total ? 0 : total - pendingWithdrawals;
        return totalAssets_;
    }

    /// @notice Computes gross rewards as the change in totalAssets minus net flows.
    /// @param oldTotalAssets The previous totalAssets from the last report.
    /// @param newTotalAssets The current totalAssets value.
    /// @param netFlows The signed net deposit/withdrawal flows.
    /// @return grossRewards The gross rewards if positive, otherwise zero.
    /// @return grossRewardsSigned The signed gross rewards value.
    function _computeGrossRewards(uint256 oldTotalAssets, uint256 newTotalAssets, int256 netFlows)
        internal
        pure
        returns (uint256 grossRewards, int256 grossRewardsSigned)
    {
        int256 changeInAssets = SafeCast.toInt256(newTotalAssets) - SafeCast.toInt256(oldTotalAssets);
        // Signed arithmetic for gross rewards; not a timestamp concern.
        // slither-disable-next-line timestamp
        grossRewardsSigned = changeInAssets - netFlows;
        // Positive-rewards guard; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (grossRewardsSigned > 0) {
            grossRewards = SafeCast.toUint256(grossRewardsSigned);
        }
        return (grossRewards, grossRewardsSigned);
    }
}
