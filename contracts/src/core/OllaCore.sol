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

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract related interfaces and addresses.
    IOllaCore.CoreModules private _modules;

    /// @notice Accounting and reporting values.
    IOllaCore.AccountingState private _accountingState;
    IOllaCore.FlowCounters private _flowCounters;
    IOllaCore.LatestReport private _latestReport;

    IOllaCore.RebalanceProgress private _rebalanceProgress;

    /// @notice Target liquid assets to keep buffered for withdrawals.
    uint256 public targetBufferedAssets;

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

    /// @notice Snapshot of cumulative exit fees at the last accounting report.
    uint256 private _latestReportCumulativeExitFees;

    /// @notice Storage gap for future upgrades.
    /// @dev When adding new state variables, append them above this gap and reduce its length
    ///      by the number of slots consumed. Target: 50 gap slots across all upgradeable contracts.
    // slither-disable-next-line unused-state
    uint256[50] private __gap;

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
        __ReentrancyGuard_init();
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
        targetBufferedAssets = 0;
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
    function setProtocolFeeBP(uint256 newFeeBP) external override onlyOwner whenNotPaused whenRebalanceDone {
        if (newFeeBP > MAX_PROTOCOL_FEE_BP) revert OllaCore__InvalidFeeBP(newFeeBP);
        uint256 oldFeeBP = protocolFeeBP;
        protocolFeeBP = SafeCast.toUint16(newFeeBP);
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);
    }

    /// @inheritdoc IOllaCore
    function setTreasuryFeeSplitBP(uint256 newSplitBP) external override onlyOwner whenNotPaused whenRebalanceDone {
        if (newSplitBP < MIN_TREASURY_SPLIT_BP || newSplitBP > MAX_TREASURY_SPLIT_BP) {
            revert OllaCore__InvalidSplitBP(newSplitBP);
        }
        uint256 oldSplitBP = treasuryFeeSplitBP;
        treasuryFeeSplitBP = SafeCast.toUint16(newSplitBP);
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);
    }

    /// @inheritdoc IOllaCore
    function setSafetyModule(address newSafetyModule) external override onlyOwner whenNotPaused whenRebalanceDone {
        address oldSafetyModule = GovernanceLib.setSafetyModule(_modules, newSafetyModule);
        emit SafetyModuleUpdated(oldSafetyModule, newSafetyModule);
        _updateAccountingTimestamp(ISafetyModule(newSafetyModule));
    }

    /// @inheritdoc IOllaCore
    function setTargetBufferedAssets(uint256 newBuffer) external override onlyOwner whenNotPaused whenRebalanceDone {
        uint256 oldBuffer = targetBufferedAssets;
        targetBufferedAssets = newBuffer;
        _rebalanceIdleBuffer = 0;
        emit TargetBufferedAssetsUpdated(oldBuffer, newBuffer);
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
            if (!_hasGasForStep()) {
                _rebalanceProgress = progress;
                return (rewardsDelta, 0, 0, vaultRef.bufferedAssets());
            }
            finalizedAmount = _finalizeWithdrawals();
            uint256 pending = vaultRef.pendingWithdrawalAssets();
            // slither-disable-next-line incorrect-equality,timestamp
            if (pending == 0 || vaultRef.bufferedAssets() == 0 || finalizedAmount == 0) {
                progress.step = IOllaCore.RebalanceStep.InitiateUnstake;
            } else {
                _rebalanceProgress = progress;
                return (rewardsDelta, finalizedAmount, 0, vaultRef.bufferedAssets());
            }
        }

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.InitiateUnstake) {
            {
                (uint256 requiredBuffer,) = _computeRequiredBuffer();
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
            // slither-disable-next-line incorrect-equality,timestamp
            if (progress.stakeRemaining == 0) {
                (uint256 requiredBuffer,) = _computeRequiredBuffer();
                progress.stakeRemaining = _computeStakeRemaining(requiredBuffer);
                // slither-disable-next-line incorrect-equality,timestamp
                if (progress.stakeRemaining == 0) {
                    progress.step = IOllaCore.RebalanceStep.Done;
                }
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
    function accountingState() external view override returns (IOllaCore.AccountingState memory) {
        return _accountingState;
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
    function convertToAssetsGross(uint256 shares) external view override returns (uint256) {
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        uint256 grossAssets = _computeTotalAssets(_accountingState, vaultRef.bufferedAssets(), 0);
        uint256 grossSupply = _modules.stAztec.totalSupply() + vaultRef.pendingWithdrawalShares();
        return shares.mulDiv(grossAssets + _VIRTUAL_OFFSET, grossSupply + _VIRTUAL_OFFSET, Math.Rounding.Floor);
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
        return _computeTotalAssets(_accountingState, vaultRef.bufferedAssets(), vaultRef.pendingWithdrawalAssets());
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Runs the full accounting update pipeline: reads module state, applies updates, computes fees, and emits reports.
    function _updateAccountingInternal() internal {
        ISafetyModule safetyModuleRef = ISafetyModule(_modules.safetyModule);
        // slither-disable-start reentrancy-no-eth
        // slither-disable-start reentrancy-benign
        // slither-disable-start reentrancy-events
        // All external calls target trusted protocol contracts (SafetyModule, Vault, StakingManager);
        // callers of this path are guarded by nonReentrant.
        safetyModuleRef.checkAccountingLiveness();

        (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows, uint256 exitFeesThisPeriod) = _getFlowsSnapshot();
        (
            uint256 currentRewards,
            uint256 rewardsDelta,
            uint256 slashingDelta,
            uint256 stakedPrincipal,
            uint256 claimableRewards
        ) = _getStakingManagerState();
        _validateSlashingDelta(slashingDelta);

        uint256 rewardsAccumulatorBalance = _getRewardsAccumulatorBalance();

        _applyAccountingUpdates(
            stakedPrincipal, rewardsAccumulatorBalance, claimableRewards, rewardsDelta, slashingDelta
        );

        _computeAndFinalizeAccounting(safetyModuleRef, flowsSnapshot, netFlows, exitFeesThisPeriod, currentRewards);
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
            _accountingState.cumulativeRewards += rewardsDelta;
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

        _accountingState.rewardsAccumulatorBalance = 0;
        emit RewardsAccumulatorFundsPulled(rewardsAccumulatorBalance);
        return rewardsAccumulatorBalance;
    }

    // Reads _modules fields and _accountingState atomically for correctness.
    /// @notice Claims exited unstaked funds from StakingManager and forwards them to the Vault.
    /// @return receivedAmount The actual token amount received.
    // slither-disable-next-line pess-multiple-storage-read
    function _pullUnstakedFunds() internal returns (uint256 receivedAmount) {
        IERC20 assetRef = _modules.asset;
        uint256 balanceBefore = assetRef.balanceOf(address(this));

        uint256 exitAmount;
        // Trusted StakingManager; transfers unstaked funds to this contract.
        // slither-disable-next-line reentrancy-benign
        (receivedAmount, exitAmount) = _modules.stakingManager.getUnstakedFunds();

        uint256 balanceAfter = assetRef.balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;

        if (receivedAmount != 0 && receivedAmount != actualReceived) {
            revert OllaCore__UnstakedFundsMismatch(receivedAmount, actualReceived);
        }

        // Forward received funds to Vault
        if (actualReceived > 0) {
            IOllaVault vaultRef = IOllaVault(_modules.vault);
            assetRef.safeTransfer(address(vaultRef), actualReceived);
            vaultRef.receiveUnstaked(actualReceived);
            emit UnstakedFundsClaimed(actualReceived);
        }

        // Positive-amount guard; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (exitAmount > 0) {
            if (exitAmount > _accountingState.stakedPrincipal) {
                exitAmount = _accountingState.stakedPrincipal;
            }
            _accountingState.stakedPrincipal -= exitAmount;
        }

        return actualReceived;
    }

    /// @notice Instructs the Vault to finalize pending withdrawal requests using available buffered assets.
    /// @return finalizedAmount The total assets used for finalization.
    function _finalizeWithdrawals() internal returns (uint256 finalizedAmount) {
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

        uint256 finalizedCount;
        // Trusted Vault; finalizes pending withdrawal queue entries.
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
        (finalizedAmount, finalizedCount) = vaultRef.finalizeWithdrawals(available, _withdrawalRate(vaultRef));

        emit WithdrawalFinalized(available, finalizedAmount);
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
            // Stake failed entirely -- return all assets to Vault
            assetRef.safeTransfer(address(vaultRef), stakeable);
            vaultRef.receiveUnstaked(stakeable);
            return 0;
        }

        // Return any excess (stakeable - actualStaked) to Vault
        uint256 excess = stakeable - totalStaked;
        if (excess > 0) {
            assetRef.safeTransfer(address(vaultRef), excess);
            vaultRef.receiveUnstaked(excess);
        }

        // Benign: calls go to trusted vault/stakingManager within nonReentrant rebalance().
        // slither-disable-next-line timestamp,reentrancy-benign
        if (totalStaked > 0) {
            _accountingState.stakedPrincipal += totalStaked;
        }

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
        uint256 updatedCumulativeDeposits,
        uint256 updatedCumulativeWithdrawals,
        uint256 updatedCumulativeSlashingAdjustments,
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
        flows.latestReportCumulativeDeposits = updatedCumulativeDeposits;
        flows.latestReportCumulativeWithdrawals = updatedCumulativeWithdrawals;
        flows.latestReportCumulativeSlashingAdjustments = updatedCumulativeSlashingAdjustments;
    }

    // Writes all accounting bucket fields atomically.
    /// @notice Writes fresh staking/reward/slashing values into the accounting state storage.
    // slither-disable-next-line pess-multiple-storage-read
    function _applyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsAccumulatorBalance,
        uint256 newClaimableRewards,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) internal {
        IOllaCore.AccountingState storage stateSnapshot = _accountingState;
        stateSnapshot.stakedPrincipal = newStakedPrincipal;
        stateSnapshot.rewardsAccumulatorBalance = newRewardsAccumulatorBalance;
        stateSnapshot.claimableRewards = newClaimableRewards;
        stateSnapshot.rewardsDelta = newRewardsDelta;
        stateSnapshot.slashingDelta = newSlashingDelta;
    }

    /// @notice Computes updated accounting outputs, runs safety checks, and persists the final report.
    /// @param safetyModuleRef The SafetyModule instance for rate-drop and queue-ratio checks.
    /// @param flowsSnapshot The flow counters snapshot for the current accounting cycle.
    /// @param netFlows The signed net deposit/withdrawal flows since the last report.
    /// @param exitFeesThisPeriod The instant-redemption fees collected since the last report.
    /// @param currentRewards The cumulative rewards value used for the report snapshot.
    function _computeAndFinalizeAccounting(
        ISafetyModule safetyModuleRef,
        IOllaCore.FlowCounters memory flowsSnapshot,
        int256 netFlows,
        uint256 exitFeesThisPeriod,
        uint256 currentRewards
    ) internal {
        (uint256 oldTotalAssets, uint256 oldRate) = _getLatestReport();
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        uint256 pendingWithdrawals = vaultRef.pendingWithdrawalAssets();
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
        ) = _computeAccountingOutputs(oldTotalAssets, netFlows, pendingWithdrawals, exitFeesThisPeriod);

        // Trusted SafetyModule; may trigger circuit breaker but holds no funds.
        // slither-disable-next-line reentrancy-no-eth
        safetyModuleRef.checkQueueRatio(pendingWithdrawals, totalAssets());
        _validateRateDrop(safetyModuleRef, oldRate, rate);
        _updateReportingSnapshots(
            newTotalAssets,
            rate,
            grossRewards,
            netFlows,
            flowsSnapshot.cumulativeDeposits,
            flowsSnapshot.cumulativeWithdrawals,
            flowsSnapshot.cumulativeSlashingAdjustments,
            currentRewards
        );
        _latestReportCumulativeExitFees = vaultRef.cumulativeExitFees();
        _updateAccountingTimestamp(safetyModuleRef);
        _emitAccountingReport(
            newTotalAssets, rate, grossRewards, netFlows, protocolFeeAssets, treasuryShares, providerShares
        );
    }

    /// @notice Derives totalAssets, gross rewards, protocol fees, and the new exchange rate.
    /// @dev `grossRewards` excludes exit fees - they are redistribution to remaining holders,
    ///      not new staking yield. Use `grossRewards` for yield/APR calculations.
    ///      `totalAssets()` includes exit fee revenue implicitly via `_bufferedAssets`.
    ///      Use `totalAssets()` for total protocol value / solvency checks.
    /// @param oldTotalAssets The previous totalAssets from the last report.
    /// @param netFlows The signed net deposit/withdrawal flows since the last report.
    /// @param pendingWithdrawals The current pending withdrawal asset amount.
    /// @param exitFeesThisPeriod The instant-redemption fees collected since the last report.
    /// @return newTotalAssets The updated total assets value.
    /// @return grossRewards The gross rewards earned this period (excludes exit fee revenue).
    /// @return protocolFeeAssets The protocol fee amount in assets.
    /// @return treasuryShares The shares minted to treasury.
    /// @return providerShares The shares minted to the provider.
    /// @return rate The new exchange rate.
    function _computeAccountingOutputs(
        uint256 oldTotalAssets,
        int256 netFlows,
        uint256 pendingWithdrawals,
        uint256 exitFeesThisPeriod
    )
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
        newTotalAssets = _computeTotalAssets(_accountingState, vaultRef.bufferedAssets(), pendingWithdrawals);
        int256 grossRewardsSigned;
        (grossRewards, grossRewardsSigned) = _computeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        // Signed comparison for negative rewards detection; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (grossRewardsSigned < 0) {
            emit NegativeRewardsPeriod(grossRewardsSigned);
        }
        // Exclude exit fee revenue from rewards before computing protocol fees.
        // Exit fees are a pure redistribution to remaining holders, not staking yield.
        if (grossRewards > exitFeesThisPeriod) {
            grossRewards -= exitFeesThisPeriod;
        } else {
            grossRewards = 0;
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

    /// @notice Emits AttestersStateRead and AccountingUpdated events for the current accounting cycle.
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
        emit AttestersStateRead(_accountingState.rewardsDelta, _accountingState.slashingDelta, _latestReport.timestamp);
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

    /// @notice Reads staking state from StakingManager: cumulative rewards, deltas, principal, and claimable.
    /// @return currentRewards The cumulative rewards including claimable.
    /// @return rewardsDelta The positive reward delta since the last report.
    /// @return slashingDelta The cumulative slashing delta.
    /// @return stakedPrincipal The total staked principal.
    /// @return claimableRewards The claimable rewards from StakingManager.
    function _getStakingManagerState()
        internal
        view
        returns (
            uint256 currentRewards,
            uint256 rewardsDelta,
            uint256 slashingDelta,
            uint256 stakedPrincipal,
            uint256 claimableRewards
        )
    {
        IOllaCore.CoreModules memory modules = _modules;
        IOllaCore.AccountingState memory accountingSnapshot = _accountingState;
        claimableRewards = modules.stakingManager.getClaimableRewards();
        currentRewards = accountingSnapshot.cumulativeRewards + claimableRewards;

        uint256 latestReportRewards = _latestReport.rewardsSnapshot;

        // Signed arithmetic for reward delta computation; not a timestamp concern.
        // slither-disable-next-line timestamp
        int256 rewardsDeltaSigned = SafeCast.toInt256(currentRewards) - SafeCast.toInt256(latestReportRewards);

        // Positive-delta guard; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (rewardsDeltaSigned > 0) {
            rewardsDelta = SafeCast.toUint256(rewardsDeltaSigned);
        }
        slashingDelta = modules.stakingManager.getSlashingDelta();
        stakedPrincipal = modules.stakingManager.totalStaked();
        return (currentRewards, rewardsDelta, slashingDelta, stakedPrincipal, claimableRewards);
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
        if (rewardsAccumulatorBalance > 0) return true;

        if (_modules.stakingManager.getClaimableRewards() > 0) return true;

        if (_modules.stakingManager.hasFinalizedUnstakes()) return true;

        IOllaVault vaultRef = IOllaVault(_modules.vault);
        uint256 pendingWithdrawals = vaultRef.pendingWithdrawalAssets();
        if (pendingWithdrawals > 0 && vaultRef.bufferedAssets() > 0) return true;

        // Surplus buffer that can actually be staked (keys available + amount >= threshold).
        uint256 currentBuffer = vaultRef.bufferedAssets();
        if (currentBuffer > targetBufferedAssets) {
            uint256 surplus = currentBuffer - targetBufferedAssets;
            if (_modules.stakingManager.canStake(surplus)) return true;
        }

        return false;
    }

    /// @notice Computes the buffer required to cover pending withdrawals plus the target buffer.
    /// @return requiredBuffer The total buffer needed.
    /// @return pendingWithdrawals The current pending withdrawal asset amount.
    function _computeRequiredBuffer() internal view returns (uint256 requiredBuffer, uint256 pendingWithdrawals) {
        pendingWithdrawals = IOllaVault(_modules.vault).pendingWithdrawalAssets();
        uint256 targetBuffered = targetBufferedAssets;
        requiredBuffer = pendingWithdrawals + targetBuffered;
        return (requiredBuffer, pendingWithdrawals);
    }

    /// @notice Calculates how much more needs to be unstaked to meet the required buffer, net of pending unstakes.
    /// @param requiredBuffer The total buffer needed to cover withdrawals and target.
    /// @return remaining The additional amount to unstake.
    function _computeUnstakeRemaining(uint256 requiredBuffer) internal view returns (uint256 remaining) {
        uint256 currentBuffer = IOllaVault(_modules.vault).bufferedAssets();
        // Buffer sufficiency check; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (requiredBuffer < currentBuffer) return 0;
        uint256 amountToUnstake = requiredBuffer - currentBuffer;
        uint256 pendingUnstakes = _modules.stakingManager.pendingUnstakes();
        // Pending unstakes already cover the deficit; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (pendingUnstakes > amountToUnstake) return 0;
        remaining = amountToUnstake - pendingUnstakes;
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
    /// @return exitFeesThisPeriod The instant-redemption fees collected since the last report.
    function _getFlowsSnapshot()
        internal
        view
        returns (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows, uint256 exitFeesThisPeriod)
    {
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
        uint256 currentCumulativeExitFees = vaultRef.cumulativeExitFees();
        exitFeesThisPeriod = currentCumulativeExitFees > _latestReportCumulativeExitFees
            ? currentCumulativeExitFees - _latestReportCumulativeExitFees
            : 0;
        return (flowsSnapshot, netFlows, exitFeesThisPeriod);
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

    /// @notice Validates that the cumulative slashing delta is monotonically non-decreasing.
    /// @param slashingDelta The new cumulative slashing delta to validate.
    function _validateSlashingDelta(uint256 slashingDelta) internal view {
        uint256 previousSlashingDelta = _accountingState.slashingDelta;
        // Monotonicity check on cumulative slashing; not a timestamp concern.
        // slither-disable-next-line timestamp
        if (slashingDelta < previousSlashingDelta) {
            revert OllaCore__InvalidSlashingDelta(previousSlashingDelta, slashingDelta);
        }
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

    /// @dev Core is the pricing authority because it owns totalAssets() (computed from _accountingState).
    ///      The Vault delegates pricing to Core via cross-contract calls to avoid circular dependencies.
    ///      Rate reflects state as of the last `updateAccounting()` or `rebalance()` call.
    ///      Accrued rewards and pending slashing between updates are not reflected.
    ///      Keeper infrastructure should call `updateAccounting()` at a cadence that
    ///      bounds the staleness window to an acceptable level for depositors.
    function _exchangeRate() internal view returns (uint256) {
        return (totalAssets() + _VIRTUAL_OFFSET)
        .mulDiv(_EXCHANGE_RATE_SCALE, _modules.stAztec.totalSupply() + _VIRTUAL_OFFSET, Math.Rounding.Floor);
    }

    /// @notice Computes the exchange rate for withdrawal queue finalization.
    /// @dev Uses gross total assets (before subtracting pending withdrawals) and gross total supply
    ///      (including shares burned for pending requests). This ensures the rate reflects the true
    ///      backing per share for adjustment after slashing, matching the rate stored at request time.
    /// @param vaultRef The vault reference.
    /// @return The withdrawal-safe exchange rate.
    function _withdrawalRate(IOllaVault vaultRef) internal view returns (uint256) {
        uint256 buffered = vaultRef.bufferedAssets();
        uint256 grossAssets = _computeTotalAssets(_accountingState, buffered, 0);
        uint256 grossSupply = _modules.stAztec.totalSupply() + vaultRef.pendingWithdrawalShares();
        return (grossAssets + _VIRTUAL_OFFSET)
        .mulDiv(_EXCHANGE_RATE_SCALE, grossSupply + _VIRTUAL_OFFSET, Math.Rounding.Floor);
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
        returns (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        // Cumulative counter comparison; not a timestamp concern.
        // slither-disable-next-line timestamp
        netDeposits = flows.cumulativeDeposits > flows.latestReportCumulativeDeposits
            ? flows.cumulativeDeposits - flows.latestReportCumulativeDeposits
            : 0;
        // Cumulative counter comparison; not a timestamp concern.
        // slither-disable-next-line timestamp
        netWithdrawals = flows.cumulativeWithdrawals > flows.latestReportCumulativeWithdrawals
            ? flows.cumulativeWithdrawals - flows.latestReportCumulativeWithdrawals
            : 0;
        // Subtract slashing adjustments that occurred since last report.
        // slither-disable-next-line timestamp
        uint256 adjustmentsSinceReport = flows.cumulativeSlashingAdjustments
                > flows.latestReportCumulativeSlashingAdjustments
            ? flows.cumulativeSlashingAdjustments - flows.latestReportCumulativeSlashingAdjustments
            : 0;
        netWithdrawals = netWithdrawals > adjustmentsSinceReport ? netWithdrawals - adjustmentsSinceReport : 0;
        netFlows = SafeCast.toInt256(netDeposits) - SafeCast.toInt256(netWithdrawals);
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
