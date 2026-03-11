// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";

// solhint-disable max-states-count
/// @title MockStakingManager
/// @notice Minimal staking manager mock for message routing tests.
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

    /// @notice Simulated staked amount for getStakingState.
    uint256 private _stakedAmount;

    /// @notice Simulated active attester count.
    uint256 public activatedAttesterCount;

    /// @notice Simulated exiting attester count.
    uint256 public pendingUnstakeCount;

    /// @notice Mock provider config.
    ProviderConfig private _providerConfig;

    /// @notice Cached attester state.
    StakingState private _cachedState;

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

    /// @notice Records a stake request.
    /// @param amount The amount to stake.
    /// @return stakedAmount The amount staked.
    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        lastStakeAmount = amount;
        _stakedAmount += amount;
        ++stakeCalls;
        return amount;
    }

    /// @notice Records an unstake request.
    /// @param amount The amount to unstake.
    /// @return unstakedAmount The amount unstaked.
    function unstake(uint256 amount) external override returns (uint256 unstakedAmount) {
        lastUnstakeAmount = amount;
        unstakedAmount = amount;
        if (unstakedAmount > _stakedAmount) {
            unstakedAmount = _stakedAmount;
        }
        _stakedAmount -= unstakedAmount;
        if (activatedAttesterCount > 0) {
            --activatedAttesterCount;
            ++pendingUnstakeCount;
        }
        ++unstakeCalls;
        return unstakedAmount;
    }

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
    function hasExitableUnstakes() external view override returns (bool) {
        return _cachedState.withdrawableAmount != 0;
    }

    /// @inheritdoc IStakingManager
    function canStake(uint256) external pure override returns (bool) {
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function getClaimableRewards() external pure override returns (uint256 claimableRewards) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getUnstakedFunds()
        external
        pure
        override
        returns (uint256 received, uint256 exitAmount, bool hasRemainingExits)
    {
        return (0, 0, false);
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
