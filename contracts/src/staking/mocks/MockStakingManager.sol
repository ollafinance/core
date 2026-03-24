// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";

// solhint-disable max-states-count
/// @title MockStakingManager
/// @notice Minimal staking manager mock for message routing tests.
/// @dev Uses `_cachedState.stakedAmount` as the single source of truth for staked totals.
///      `stake()` and `unstake()` both update `_cachedState.stakedAmount` so that
///      `totalStaked()` and `getStakingState()` return consistent values.
/// @author Olla Core contributors
contract MockStakingManager is IStakingManager {
    /// @notice The core contract address.
    address public core;

    /// @notice The staking provider registry.
    IStakingProviderRegistry private _stakingProviderRegistry;

    /// @notice Last amount requested to stake.
    uint256 public lastStakeAmount;

    /// @notice Last amount requested to unstake.
    uint256 public lastUnstakeAmount;

    /// @notice Number of stake calls received.
    uint256 public stakeCalls;

    /// @notice Number of unstake calls received.
    uint256 public unstakeCalls;

    /// @notice Simulated active attester count.
    uint256 public activatedAttesterCount;

    /// @notice Simulated exiting attester count.
    uint256 public pendingUnstakeCount;

    /// @notice Mock provider config.
    ProviderConfig private _providerConfig;

    /// @notice Aggregated staking state (single source of truth for staked totals).
    StakingState private _cachedState;

    /// @notice Configurable canStake return value. Default true.
    bool private _canStakeEnabled = true;

    /// @notice Configurable claimable rewards return value. Default 0.
    uint256 private _claimableRewards;

    /// @notice Configurable hasFinalizedUnstakes return value. Default false.
    bool private _hasFinalizedUnstakes;

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice No-op initializer for interface compatibility.
    /// @param stakingAsset Unused.
    /// @param rollupRegistry Unused.
    /// @param rewardsAccumulator Unused.
    /// @param core_ The core contract address.
    /// @param stakingProviderRegistry_ The staking provider registry address.
    /// @param defaultAdmin Unused.
    function initialize(
        IERC20 stakingAsset,
        address rollupRegistry,
        address rewardsAccumulator,
        address core_,
        address stakingProviderRegistry_,
        address defaultAdmin
    ) external override {
        stakingAsset;
        rollupRegistry;
        rewardsAccumulator;
        core = core_;
        _stakingProviderRegistry = IStakingProviderRegistry(stakingProviderRegistry_);
        defaultAdmin;
        return;
    }

    /// @notice Records a stake request and updates _cachedState.stakedAmount.
    /// @param amount The amount to stake.
    /// @return stakedAmount The amount staked.
    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        lastStakeAmount = amount;
        _cachedState.stakedAmount += amount;
        ++stakeCalls;
        return amount;
    }

    /// @notice Records an unstake request and updates _cachedState.stakedAmount.
    /// @param amount The amount to unstake.
    /// @return unstakedAmount The amount unstaked.
    function unstake(uint256 amount) external override returns (uint256 unstakedAmount) {
        lastUnstakeAmount = amount;
        unstakedAmount = amount;
        if (unstakedAmount > _cachedState.stakedAmount) {
            unstakedAmount = _cachedState.stakedAmount;
        }
        _cachedState.stakedAmount -= unstakedAmount;
        if (activatedAttesterCount > 0) {
            --activatedAttesterCount;
            ++pendingUnstakeCount;
        }
        ++unstakeCalls;
        return unstakedAmount;
    }

    /*//////////////////////////////////////////////////////////////
                         MOCK CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    // solhint-disable comprehensive-interface

    /// @notice Sets all fields of the cached staking state.
    /// @param slashingDelta The cumulative slashing delta.
    /// @param stakedAmount The total staked amount.
    /// @param pendingUnstakeAmount The total pending unstake amount.
    function mockSetCachedState(uint256 slashingDelta, uint256 stakedAmount, uint256 pendingUnstakeAmount) external {
        _cachedState.slashingDelta = slashingDelta;
        _cachedState.stakedAmount = stakedAmount;
        _cachedState.pendingUnstakeAmount = pendingUnstakeAmount;
    }

    /// @notice Sets the staked amount in the cached state.
    /// @param amount The staked amount.
    function mockSetStakedAmount(uint256 amount) external {
        _cachedState.stakedAmount = amount;
    }

    /// @notice Sets the canStake return value.
    /// @param enabled Whether canStake returns true.
    function mockSetCanStake(bool enabled) external {
        _canStakeEnabled = enabled;
    }

    /// @notice Sets the claimable rewards return value.
    /// @param amount The claimable rewards amount.
    function mockSetClaimableRewards(uint256 amount) external {
        _claimableRewards = amount;
    }

    /// @notice Sets the hasFinalizedUnstakes return value.
    /// @param value Whether hasFinalizedUnstakes returns true.
    function mockSetHasFinalizedUnstakes(bool value) external {
        _hasFinalizedUnstakes = value;
    }

    // solhint-enable comprehensive-interface

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function stakingProviderRegistry() external view override returns (IStakingProviderRegistry) {
        return _stakingProviderRegistry;
    }

    /// @inheritdoc IStakingManager
    function getStakingState() external view override returns (StakingState memory) {
        return _cachedState;
    }

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256 stakedTotal) {
        return _cachedState.stakedAmount;
    }

    /// @inheritdoc IStakingManager
    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return _providerConfig;
    }

    /// @inheritdoc IStakingManager
    function getActivatedAttesterCount() external view override returns (uint256) {
        return activatedAttesterCount;
    }

    /// @inheritdoc IStakingManager
    function getPendingUnstakeCount() external view override returns (uint256) {
        return pendingUnstakeCount;
    }

    /// @inheritdoc IStakingManager
    function getSlashingDelta() external view override returns (uint256 slashingDelta) {
        return _cachedState.slashingDelta;
    }

    /// @inheritdoc IStakingManager
    function pendingUnstakes() external view override returns (uint256) {
        return _cachedState.pendingUnstakeAmount;
    }

    /// @inheritdoc IStakingManager
    function hasFinalizedUnstakes() external view override returns (bool) {
        return _hasFinalizedUnstakes;
    }

    /// @inheritdoc IStakingManager
    function canStake(uint256) external view override returns (bool) {
        return _canStakeEnabled;
    }

    /// @inheritdoc IStakingManager
    function getClaimableRewards() external view override returns (uint256 claimableRewards) {
        return _claimableRewards;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function getUnstakedFunds() external pure override returns (uint256 received, uint256 exitAmount) {
        return (0, 0);
    }

    /// @inheritdoc IStakingManager
    function harvestRewards() external pure override returns (uint256 harvested) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function isUnstakePending(address) external pure override returns (bool) {
        return false;
    }

    /// @notice No-op in mock.
    function setGasThreshold(uint256) external pure override { }

    /// @notice No-op in mock.
    function refreshAttesterState(address[] calldata) external pure override { }
}
