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
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsCollector } from "src/core/interfaces/IRewardsCollector.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { GovernanceLib } from "src/core/libraries/GovernanceLib.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { RolesLib } from "src/shared/RolesLib.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaCore
/// @notice Orchestration + accounting layer. Manages rebalance, computes totalAssets/exchangeRate,
///         interacts with StakingManager/RewardsCollector/SafetyModule, and instructs Vault via CORE_ROLE.
/// @author Olla Core contributors
contract OllaCore is
    Initializable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IOllaCore
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant _EXCHANGE_RATE_SCALE = 1e18;
    uint256 private constant _REBALANCE_GAS_THRESHOLD = 180_000;

    /// @notice Role for guardian pause/unpause actions.
    bytes32 public constant GUARDIAN_ROLE = RolesLib.GUARDIAN_ROLE;
    /// @notice Role for operator accounting actions.
    bytes32 public constant OPERATOR_ROLE = RolesLib.OPERATOR_ROLE;

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

    /// @notice The protocol fee in basis points.
    uint256 public protocolFeeBP;

    /// @notice The treasury fee split in basis points.
    uint256 public treasuryFeeSplitBP;

    /// @notice Target liquid assets to keep buffered for withdrawals.
    uint256 public targetBufferedAssets;

    /// @notice Gas threshold used to gate rebalance step execution.
    uint256 public rebalanceGasThreshold;

    /// @notice Snapshot of bufferedAssets at the end of an unproductive rebalance cycle.
    uint256 private _rebalanceIdleBuffer;

    /// @notice Minimum seconds between permissionless rebalance cycles.
    uint256 public rebalanceCooldown;

    /// @notice Timestamp of the last completed rebalance cycle.
    uint256 private _lastRebalanceTimestamp;

    /// @notice Storage gap for upgradability.
    // slither-disable-next-line unused-state
    uint256[45] private __gap;

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
        IRewardsCollector rewardsCollector_,
        address safetyModule_
    ) external override initializer {
        _validateInitialParams(
            asset_,
            stAztec_,
            stakingManager_,
            protocolFeeBP_,
            treasuryFeeSplitBP_,
            governanceContract_,
            rewardsCollector_,
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
            rewardsCollector: rewardsCollector_,
            safetyModule: safetyModule_
        });

        protocolFeeBP = protocolFeeBP_;
        treasuryFeeSplitBP = treasuryFeeSplitBP_;
        targetBufferedAssets = 0;
        rebalanceGasThreshold = _REBALANCE_GAS_THRESHOLD;
        _rebalanceProgress.step = IOllaCore.RebalanceStep.Done;

        _modules.stakingManager.setGasThreshold(rebalanceGasThreshold);

        _latestReport.exchangeRate = _EXCHANGE_RATE_SCALE;
        // slither-disable-next-line timestamp
        _latestReport.timestamp = block.timestamp;

        rebalanceCooldown = 1 hours;
        // slither-disable-next-line timestamp
        _lastRebalanceTimestamp = block.timestamp;

        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, governanceContract_);
        _grantRole(GUARDIAN_ROLE, governanceContract_);
        _grantRole(OPERATOR_ROLE, governanceContract_);
    }

    /*//////////////////////////////////////////////////////////////
                      PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses the core.
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        _pause();
        emit Paused();
    }

    /// @notice Unpauses the core.
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        _unpause();
        emit Unpaused();
    }

    /// @inheritdoc IOllaCore
    function forceRebalanceReset() external override onlyRole(GUARDIAN_ROLE) whenNotPaused {
        _rebalanceProgress =
            IOllaCore.RebalanceProgress({ step: IOllaCore.RebalanceStep.Done, stakeRemaining: 0, unstakeRemaining: 0 });
        _rebalanceIdleBuffer = 0;
        emit RebalanceReset();
    }

    /// @notice Sets the protocol fee in basis points.
    function setProtocolFeeBP(uint256 newFeeBP) external override onlyOwner whenNotPaused whenRebalanceDone {
        if (newFeeBP > MAX_PROTOCOL_FEE_BP) revert OllaCore__InvalidFeeBP(newFeeBP);
        uint256 oldFeeBP = protocolFeeBP;
        protocolFeeBP = newFeeBP;
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);
    }

    /// @notice Sets the treasury fee split in basis points.
    function setTreasuryFeeSplitBP(uint256 newSplitBP) external override onlyOwner whenNotPaused whenRebalanceDone {
        if (newSplitBP < MIN_TREASURY_SPLIT_BP || newSplitBP > MAX_TREASURY_SPLIT_BP) {
            revert OllaCore__InvalidSplitBP(newSplitBP);
        }
        uint256 oldSplitBP = treasuryFeeSplitBP;
        treasuryFeeSplitBP = newSplitBP;
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);
    }

    /// @notice Sets the safety module address.
    function setSafetyModule(address newSafetyModule) external override onlyOwner whenNotPaused whenRebalanceDone {
        address oldSafetyModule = GovernanceLib.setSafetyModule(_modules, newSafetyModule);
        emit SafetyModuleUpdated(oldSafetyModule, newSafetyModule);
    }

    /// @notice Sets the target buffer used to reserve liquid assets.
    function setTargetBufferedAssets(uint256 newBuffer) external override onlyOwner whenNotPaused whenRebalanceDone {
        uint256 oldBuffer = targetBufferedAssets;
        targetBufferedAssets = newBuffer;
        _rebalanceIdleBuffer = 0;
        emit TargetBufferedAssetsUpdated(oldBuffer, newBuffer);
    }

    /// @notice Sets the gas threshold used for rebalance step gating.
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
        rebalanceGasThreshold = newThreshold;
        emit RebalanceGasThresholdUpdated(oldThreshold, newThreshold);
        GovernanceLib.propagateGasThreshold(_modules, newThreshold);
    }

    /// @notice Sets the rebalance cooldown.
    function setRebalanceCooldown(uint256 cooldown_) external override onlyOwner whenNotPaused whenRebalanceDone {
        if (cooldown_ < MIN_REBALANCE_COOLDOWN || cooldown_ > MAX_REBALANCE_COOLDOWN) {
            revert OllaCore__InvalidParameter();
        }
        uint256 old = rebalanceCooldown;
        rebalanceCooldown = cooldown_;
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
    // slither-disable-start pess-multiple-storage-read
    // slither-disable-start incorrect-equality,timestamp
    // solhint-disable function-max-lines
    /// @notice Permissionless rebalance flow.
    function rebalance()
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer)
    {
        ISafetyModule safetyModuleRef = ISafetyModule(_modules.safetyModule);
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        safetyModuleRef.checkAccountingLiveness();
        IOllaCore.RebalanceProgress memory progress = _rebalanceProgress;

        // slither-disable-next-line incorrect-equality
        if (progress.step == IOllaCore.RebalanceStep.Done) {
            {
                uint256 cooldown_ = rebalanceCooldown;
                uint256 elapsed = block.timestamp - _lastRebalanceTimestamp;
                // slither-disable-next-line timestamp
                // Standard cooldown check; miner manipulation (~15s) is negligible for this use case.
                if (elapsed < cooldown_) revert OllaCore__RebalanceCooldownActive(elapsed, cooldown_);
            }

            uint256 currentBuffer = vaultRef.bufferedAssets();
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
            // slither-disable-next-line reentrancy-no-eth
            rewardsDelta = _harvestRewards();
            progress.step = IOllaCore.RebalanceStep.PullUnstaked;
        }

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.PullUnstaked) {
            if (!_hasGasForStep()) {
                _rebalanceProgress = progress;
                return (rewardsDelta, 0, 0, vaultRef.bufferedAssets());
            }
            // slither-disable-next-line unused-return
            (, bool hasRemainingExits) = _pullUnstakedFunds();
            if (hasRemainingExits) {
                _rebalanceProgress = progress;
                return (rewardsDelta, 0, 0, vaultRef.bufferedAssets());
            }
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
                (uint256 requiredBuffer,) = _computeRequiredBuffer();
                progress.unstakeRemaining = _computeUnstakeRemaining(requiredBuffer);
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
                    progress.step = IOllaCore.RebalanceStep.ComputeAttesterState;
                }
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
                        progress.step = IOllaCore.RebalanceStep.ComputeAttesterState;
                    } else {
                        _rebalanceProgress = progress;
                        return (rewardsDelta, finalizedAmount, stakedAmount, vaultRef.bufferedAssets());
                    }
                }
                progress.step = IOllaCore.RebalanceStep.ComputeAttesterState;
            }
        }

        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.ComputeAttesterState) {
            if (!_hasGasForStep()) {
                _rebalanceProgress = progress;
                return (rewardsDelta, finalizedAmount, stakedAmount, vaultRef.bufferedAssets());
            }
            // slither-disable-next-line unused-return
            (, bool computeCompleted) = _modules.stakingManager.computeAttesterState();
            if (computeCompleted) {
                progress.step = IOllaCore.RebalanceStep.Done;
            } else {
                _rebalanceProgress = progress;
                return (rewardsDelta, finalizedAmount, stakedAmount, vaultRef.bufferedAssets());
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
            _lastRebalanceTimestamp = block.timestamp;
            _updateAccountingInternal();
        }

        return (rewardsDelta, finalizedAmount, stakedAmount, resultingBuffer);
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end cyclomatic-complexity
    // slither-disable-end incorrect-equality,timestamp
    // solhint-enable function-max-lines

    // slither-disable-start pess-multiple-storage-read
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

    /// @notice Returns the underlying asset address.
    function asset() external view override returns (address) {
        return address(_modules.asset);
    }

    /// @notice Returns the OllaVault address.
    function vault() external view override returns (address) {
        return _modules.vault;
    }

    /// @notice Returns the stAztec share token address.
    function stAztec() external view override returns (address) {
        return address(_modules.stAztec);
    }

    /// @notice Returns the staking manager address.
    function stakingManager() external view override returns (address) {
        return address(_modules.stakingManager);
    }

    /// @notice Returns the rewards vault module address.
    function rewardsCollector() external view override returns (address) {
        return address(_modules.rewardsCollector);
    }

    /// @notice Returns the safety module address.
    function safetyModule() external view override returns (address) {
        return _modules.safetyModule;
    }

    /// @notice Returns the latest accounting report snapshot.
    function latestReport() external view override returns (IOllaCore.LatestReport memory) {
        return _latestReport;
    }

    /// @notice Returns the current rebalance progress snapshot.
    function rebalanceProgress() external view override returns (IOllaCore.RebalanceProgress memory) {
        return IOllaCore.RebalanceProgress({
            step: _rebalanceProgress.step,
            stakeRemaining: _rebalanceProgress.stakeRemaining,
            unstakeRemaining: _rebalanceProgress.unstakeRemaining
        });
    }

    /// @notice Returns the flow counter snapshots.
    function flowCounters() external view override returns (IOllaCore.FlowCounters memory) {
        IOllaCore.FlowCounters memory flows = _flowCounters;
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        flows.cumulativeDeposits = vaultRef.cumulativeDeposits();
        flows.cumulativeWithdrawals = vaultRef.cumulativeWithdrawals();
        return flows;
    }

    /// @notice Returns the accounting buckets snapshot.
    function accountingState() external view override returns (IOllaCore.AccountingState memory) {
        return _accountingState;
    }

    /// @notice Returns the current exchange rate in 18-decimal fixed-point units.
    function exchangeRate() external view override returns (uint256) {
        return _exchangeRate();
    }

    /// @notice Computes the shares for an asset amount.
    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Computes the assets for a share amount (rounds down).
    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        return _convertToAssets(shares);
    }

    /// @notice Computes the assets for a share amount (rounds up).
    function convertToAssetsCeil(uint256 shares) external view override returns (uint256 assets) {
        return shares.mulDiv(totalAssets() + 1, _modules.stAztec.totalSupply() + 1, Math.Rounding.Ceil);
    }

    /// @notice Returns the current total assets attributable to shareholders.
    function totalAssets() public view override returns (uint256) {
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        return _computeTotalAssets(_accountingState, vaultRef.bufferedAssets(), vaultRef.pendingWithdrawalAssets());
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _updateAccountingInternal() internal {
        ISafetyModule safetyModuleRef = ISafetyModule(_modules.safetyModule);
        // slither-disable-start reentrancy-no-eth
        // slither-disable-start reentrancy-benign
        // slither-disable-start reentrancy-events
        safetyModuleRef.checkAccountingLiveness();

        (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows) = _getFlowsSnapshot();
        (
            uint256 currentRewards,
            uint256 rewardsDelta,
            uint256 slashingDelta,
            uint256 stakedPrincipal,
            uint256 claimableRewards
        ) = _getStakingManagerState();
        _validateSlashingDelta(slashingDelta);

        uint256 rewardsCollectorBalance = _getRewardsCollectorBalance();

        _applyAccountingUpdates(stakedPrincipal, rewardsCollectorBalance, claimableRewards, rewardsDelta, slashingDelta);

        _computeAndFinalizeAccounting(safetyModuleRef, flowsSnapshot, netFlows, currentRewards);
        // slither-disable-end reentrancy-events
        // slither-disable-end reentrancy-benign
        // slither-disable-end reentrancy-no-eth
    }

    // slither-disable-next-line reentrancy-no-eth,pess-multiple-storage-read
    function _harvestRewards() internal returns (uint256 rewardsDelta) {
        // slither-disable-next-line unused-return
        _modules.stakingManager.harvestRewards();

        IRewardsCollector rewardsCollectorRef = _modules.rewardsCollector;
        // slither-disable-next-line reentrancy-benign
        rewardsDelta = rewardsCollectorRef.recordBalance();
        if (rewardsDelta != 0) {
            _accountingState.cumulativeRewards += rewardsDelta;
        }
        emit RewardsDelta(rewardsDelta);

        _pullRewardsCollectorFunds();

        return rewardsDelta;
    }

    function _pullRewardsCollectorFunds() internal returns (uint256 pulledAmount) {
        CoreModules memory modules = _modules;
        IRewardsCollector rewardsCollectorRef = modules.rewardsCollector;
        uint256 rewardsCollectorBalance = rewardsCollectorRef.balance();

        // slither-disable-next-line timestamp,incorrect-equality
        if (rewardsCollectorBalance == 0) return 0;

        IOllaVault vaultRef = IOllaVault(modules.vault);

        // slither-disable-next-line reentrancy-benign
        rewardsCollectorRef.withdrawToCore();
        // Forward received funds to Vault
        modules.asset.safeTransfer(address(vaultRef), rewardsCollectorBalance);
        vaultRef.receiveUnstaked(rewardsCollectorBalance);

        _accountingState.rewardsCollectorBalance = 0;
        emit RewardsCollectorFundsPulled(rewardsCollectorBalance);
        return rewardsCollectorBalance;
    }

    // slither-disable-next-line pess-multiple-storage-read
    function _pullUnstakedFunds() internal returns (uint256 receivedAmount, bool hasRemainingExits) {
        IERC20 assetRef = _modules.asset;
        uint256 balanceBefore = assetRef.balanceOf(address(this));

        uint256 exitAmount;
        // slither-disable-next-line reentrancy-benign
        (receivedAmount, exitAmount, hasRemainingExits) = _modules.stakingManager.getUnstakedFunds();

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

        // slither-disable-next-line timestamp
        if (exitAmount > 0) {
            if (exitAmount > _accountingState.stakedPrincipal) {
                exitAmount = _accountingState.stakedPrincipal;
            }
            _accountingState.stakedPrincipal -= exitAmount;
        }

        return (actualReceived, hasRemainingExits);
    }

    function _finalizeWithdrawals() internal returns (uint256 finalizedAmount) {
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        uint256 available = vaultRef.bufferedAssets();

        // slither-disable-next-line timestamp,incorrect-equality
        if (available == 0) return 0;

        uint256 queued = vaultRef.pendingWithdrawalAssets();
        uint256 total = totalAssets();

        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
        ISafetyModule(_modules.safetyModule).checkQueueRatio(queued, total);

        // slither-disable-next-line timestamp,incorrect-equality
        if (queued == 0) return 0;

        uint256 finalizedCount;
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
        (finalizedAmount, finalizedCount) = vaultRef.finalizeWithdrawals(available);

        emit WithdrawalFinalized(available, finalizedAmount);
        return finalizedAmount;
    }

    // slither-disable-start pess-multiple-storage-read,reentrancy-benign
    // Benign reentrancy: calls go to trusted vault/stakingManager within nonReentrant rebalance().
    function _stakeSurplus(uint256 stakeable) internal returns (uint256 totalStaked) {
        // slither-disable-next-line incorrect-equality,timestamp
        if (stakeable == 0) return 0;

        IOllaVault vaultRef = IOllaVault(_modules.vault);
        IStakingManager stakingManagerRef = _modules.stakingManager;

        IERC20 assetRef = _modules.asset;

        // Pull assets from Vault to Core, then approve StakingManager to pull from Core.
        // This preserves the StakingManager's existing `safeTransferFrom(core, ...)` pattern.
        vaultRef.transferToCore(stakeable);
        assetRef.forceApprove(address(stakingManagerRef), stakeable);

        // slither-disable-next-line reentrancy-no-eth
        try stakingManagerRef.stake(stakeable) returns (uint256 actualStaked) {
            // slither-disable-next-line timestamp
            if (actualStaked > stakeable) revert OllaCore__StakeFailed(actualStaked);
            totalStaked = actualStaked;
        } catch {
            // Stake failed entirely — return all assets to Vault
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

        // slither-disable-next-line timestamp,reentrancy-benign
        // Benign: calls go to trusted vault/stakingManager within nonReentrant rebalance().
        if (totalStaked > 0) {
            _accountingState.stakedPrincipal += totalStaked;
        }

        return totalStaked;
    }

    // slither-disable-end pess-multiple-storage-read,reentrancy-benign

    // slither-disable-start pess-unprotected-initialize
    function _initiateUnstake(uint256 requested) internal returns (uint256 initiated) {
        // slither-disable-next-line incorrect-equality,timestamp
        if (requested == 0) return 0;

        IStakingManager stakingManagerRef = _modules.stakingManager;
        uint256 pendingUnstakes = stakingManagerRef.pendingUnstakes();

        // slither-disable-next-line reentrancy-no-eth
        initiated = stakingManagerRef.unstake(requested);
        // slither-disable-next-line timestamp
        if (initiated > 0) {
            emit UnstakeInitiated(requested + pendingUnstakes, initiated);
        }
        return initiated;
    }

    // slither-disable-end pess-unprotected-initialize

    /// @notice Payout protocol fees through minting shares via Vault.
    function _payoutOllaProtocolFees(uint256 grossAssetRewards)
        internal
        returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
    {
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

    // slither-disable-next-line pess-multiple-storage-read
    function _updateReportingSnapshots(
        uint256 total,
        uint256 rate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 updatedCumulativeDeposits,
        uint256 updatedCumulativeWithdrawals,
        uint256 rewardsSnapshot
    ) internal {
        IOllaCore.LatestReport storage report = _latestReport;
        report.totalAssets = total;
        report.exchangeRate = rate;
        report.grossRewards = grossRewards;
        report.netFlows = netFlows;
        report.rewardsSnapshot = rewardsSnapshot;
        // slither-disable-next-line timestamp
        report.timestamp = block.timestamp;

        IOllaCore.FlowCounters storage flows = _flowCounters;
        flows.latestReportCumulativeDeposits = updatedCumulativeDeposits;
        flows.latestReportCumulativeWithdrawals = updatedCumulativeWithdrawals;
    }

    // slither-disable-next-line pess-multiple-storage-read
    function _applyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsCollectorBalance,
        uint256 newClaimableRewards,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) internal {
        IOllaCore.AccountingState storage stateSnapshot = _accountingState;
        stateSnapshot.stakedPrincipal = newStakedPrincipal;
        stateSnapshot.rewardsCollectorBalance = newRewardsCollectorBalance;
        stateSnapshot.claimableRewards = newClaimableRewards;
        stateSnapshot.rewardsDelta = newRewardsDelta;
        stateSnapshot.slashingDelta = newSlashingDelta;
    }

    function _computeAndFinalizeAccounting(
        ISafetyModule safetyModuleRef,
        IOllaCore.FlowCounters memory flowsSnapshot,
        int256 netFlows,
        uint256 currentRewards
    ) internal {
        (uint256 oldTotalAssets, uint256 oldRate) = _getLatestReport();
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        uint256 pendingWithdrawals = vaultRef.pendingWithdrawalAssets();
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
            currentRewards
        );
        _updateAccountingTimestamp(safetyModuleRef);
        _emitAccountingReport(
            newTotalAssets, rate, grossRewards, netFlows, protocolFeeAssets, treasuryShares, providerShares
        );
    }

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
        newTotalAssets = _computeTotalAssets(_accountingState, vaultRef.bufferedAssets(), pendingWithdrawals);
        int256 grossRewardsSigned;
        (grossRewards, grossRewardsSigned) = _computeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        // slither-disable-next-line timestamp
        if (grossRewardsSigned < 0) {
            emit NegativeRewardsPeriod(grossRewardsSigned);
        }
        (protocolFeeAssets, treasuryShares, providerShares) = _payoutOllaProtocolFees(grossRewards);
        rate = _exchangeRate();
        return (newTotalAssets, grossRewards, protocolFeeAssets, treasuryShares, providerShares, rate);
    }

    function _validateRateDrop(ISafetyModule safetyModuleRef, uint256 oldRate, uint256 rate) internal {
        safetyModuleRef.checkRateDrop(oldRate, rate);
    }

    function _updateAccountingTimestamp(ISafetyModule safetyModuleRef) internal {
        // slither-disable-next-line timestamp
        safetyModuleRef.setLatestAccountingTimestamp(block.timestamp);
    }

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

        // slither-disable-next-line timestamp
        int256 rewardsDeltaSigned = SafeCast.toInt256(currentRewards) - SafeCast.toInt256(latestReportRewards);

        // slither-disable-next-line timestamp
        if (rewardsDeltaSigned > 0) {
            rewardsDelta = SafeCast.toUint256(rewardsDeltaSigned);
        }
        slashingDelta = modules.stakingManager.getSlashingDelta();
        stakedPrincipal = modules.stakingManager.totalStaked();
        return (currentRewards, rewardsDelta, slashingDelta, stakedPrincipal, claimableRewards);
    }

    function _hasGasForStep() internal view returns (bool) {
        return gasleft() > rebalanceGasThreshold;
    }

    // slither-disable-next-line timestamp,pess-multiple-storage-read
    function _hasRebalanceWorkAvailable() internal view returns (bool) {
        uint256 rewardsCollectorBalance = _getRewardsCollectorBalance();
        if (rewardsCollectorBalance > 0) return true;

        if (_modules.stakingManager.getClaimableRewards() > 0) return true;

        if (_modules.stakingManager.hasExitableUnstakes()) return true;

        IOllaVault vaultRef = IOllaVault(_modules.vault);
        uint256 pendingWithdrawals = vaultRef.pendingWithdrawalAssets();
        if (pendingWithdrawals > 0 && vaultRef.bufferedAssets() > 0) return true;

        return false;
    }

    function _computeRequiredBuffer() internal view returns (uint256 requiredBuffer, uint256 pendingWithdrawals) {
        pendingWithdrawals = IOllaVault(_modules.vault).pendingWithdrawalAssets();
        uint256 targetBuffered = targetBufferedAssets;
        requiredBuffer = pendingWithdrawals + targetBuffered;
        return (requiredBuffer, pendingWithdrawals);
    }

    function _computeUnstakeRemaining(uint256 requiredBuffer) internal view returns (uint256 remaining) {
        uint256 currentBuffer = IOllaVault(_modules.vault).bufferedAssets();
        // slither-disable-next-line timestamp
        if (requiredBuffer < currentBuffer) return 0;
        uint256 amountToUnstake = requiredBuffer - currentBuffer;
        uint256 pendingUnstakes = _modules.stakingManager.pendingUnstakes();
        // slither-disable-next-line timestamp
        if (pendingUnstakes > amountToUnstake) return 0;
        remaining = amountToUnstake - pendingUnstakes;
        return remaining;
    }

    function _computeStakeRemaining(uint256 requiredBuffer) internal view returns (uint256 remaining) {
        uint256 currentBuffer = IOllaVault(_modules.vault).bufferedAssets();
        // slither-disable-next-line timestamp
        if (currentBuffer < requiredBuffer) return 0;
        remaining = currentBuffer - requiredBuffer;
        return remaining;
    }

    function _getFlowsSnapshot() internal view returns (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows) {
        IOllaVault vaultRef = IOllaVault(_modules.vault);
        flowsSnapshot = IOllaCore.FlowCounters({
            cumulativeDeposits: vaultRef.cumulativeDeposits(),
            cumulativeWithdrawals: vaultRef.cumulativeWithdrawals(),
            latestReportCumulativeDeposits: _flowCounters.latestReportCumulativeDeposits,
            latestReportCumulativeWithdrawals: _flowCounters.latestReportCumulativeWithdrawals
        });
        (netFlows,,) = _computeNetFlows(flowsSnapshot);
        return (flowsSnapshot, netFlows);
    }

    function _getLatestReport() internal view returns (uint256 reportedTotalAssets, uint256 reportedExchangeRate) {
        IOllaCore.LatestReport memory report = _latestReport;
        return (report.totalAssets, report.exchangeRate);
    }

    function _getRewardsCollectorBalance() internal view returns (uint256 rewardsCollectorBalance) {
        return IRewardsCollector(_modules.rewardsCollector).balance();
    }

    function _validateSlashingDelta(uint256 slashingDelta) internal view {
        uint256 previousSlashingDelta = _accountingState.slashingDelta;
        // slither-disable-next-line timestamp
        if (slashingDelta < previousSlashingDelta) {
            revert OllaCore__InvalidSlashingDelta(previousSlashingDelta, slashingDelta);
        }
    }

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
    function _exchangeRate() internal view returns (uint256) {
        return (totalAssets() + 1).mulDiv(_EXCHANGE_RATE_SCALE, _modules.stAztec.totalSupply() + 1, Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, _modules.stAztec.totalSupply() + 1, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(_modules.stAztec.totalSupply() + 1, totalAssets() + 1, rounding);
    }

    function _treasury() internal view returns (address) {
        return IOllaGovernance(owner()).treasury();
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert OllaCore__ZeroAddress("newImplementation");
    }

    function _rebalanceCompletionSatisfied(IOllaCore.RebalanceProgress memory progress) internal pure returns (bool) {
        // slither-disable-next-line incorrect-equality,timestamp
        return progress.step == IOllaCore.RebalanceStep.Done;
    }

    function _validateInitialParams(
        IERC20 asset_,
        IStAztec stAztec_,
        IStakingManager stakingManager_,
        uint256 protocolFeeBP_,
        uint256 treasuryFeeSplitBP_,
        address governanceContract_,
        IRewardsCollector rewardsCollector_,
        address safetyModule_
    ) internal pure {
        if (address(asset_) == address(0)) revert OllaCore__ZeroAddress("asset_");
        if (address(stAztec_) == address(0)) revert OllaCore__ZeroAddress("stAztec_");
        if (address(stakingManager_) == address(0)) revert OllaCore__ZeroAddress("stakingManager_");
        if (protocolFeeBP_ > MAX_PROTOCOL_FEE_BP) revert OllaCore__InvalidFeeBP(protocolFeeBP_);
        if (treasuryFeeSplitBP_ < MIN_TREASURY_SPLIT_BP || treasuryFeeSplitBP_ > MAX_TREASURY_SPLIT_BP) {
            revert OllaCore__InvalidSplitBP(treasuryFeeSplitBP_);
        }
        if (governanceContract_ == address(0)) revert OllaCore__ZeroAddress("governanceContract_");
        if (address(rewardsCollector_) == address(0)) revert OllaCore__ZeroAddress("rewardsCollector_");
        if (safetyModule_ == address(0)) revert OllaCore__ZeroAddress("safetyModule_");
    }

    function _computeNetFlows(IOllaCore.FlowCounters memory flows)
        internal
        pure
        returns (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        // slither-disable-next-line timestamp
        netDeposits = flows.cumulativeDeposits > flows.latestReportCumulativeDeposits
            ? flows.cumulativeDeposits - flows.latestReportCumulativeDeposits
            : 0;
        // slither-disable-next-line timestamp
        netWithdrawals = flows.cumulativeWithdrawals > flows.latestReportCumulativeWithdrawals
            ? flows.cumulativeWithdrawals - flows.latestReportCumulativeWithdrawals
            : 0;
        netFlows = SafeCast.toInt256(netDeposits) - SafeCast.toInt256(netWithdrawals);
        return (netFlows, netDeposits, netWithdrawals);
    }

    function _computeTotalAssets(
        IOllaCore.AccountingState memory buckets,
        uint256 bufferedAssets,
        uint256 pendingWithdrawals
    ) internal pure returns (uint256 totalAssets_) {
        uint256 total = bufferedAssets + buckets.stakedPrincipal + buckets.rewardsCollectorBalance
            + buckets.claimableRewards;
        // slither-disable-next-line timestamp
        if (buckets.slashingDelta >= total) return 0;
        total -= buckets.slashingDelta;
        totalAssets_ = pendingWithdrawals >= total ? 0 : total - pendingWithdrawals;
        return totalAssets_;
    }

    function _computeGrossRewards(uint256 oldTotalAssets, uint256 newTotalAssets, int256 netFlows)
        internal
        pure
        returns (uint256 grossRewards, int256 grossRewardsSigned)
    {
        int256 changeInAssets = SafeCast.toInt256(newTotalAssets) - SafeCast.toInt256(oldTotalAssets);
        // slither-disable-next-line timestamp
        grossRewardsSigned = changeInAssets - netFlows;
        // slither-disable-next-line timestamp
        if (grossRewardsSigned > 0) {
            grossRewards = SafeCast.toUint256(grossRewardsSigned);
        }
        return (grossRewards, grossRewardsSigned);
    }
}
