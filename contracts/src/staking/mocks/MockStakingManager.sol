// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";

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

    /// @notice Mock provider config.
    ProviderConfig private _providerConfig;

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice No-op initializer for interface compatibility.
    /// @param stakingAsset Unused.
    /// @param rollupRegistry Unused.
    /// @param rewardsVault Unused.
    /// @param core_ The core contract address.
    /// @param stakingProviderRegistry_ The staking provider registry address.
    /// @param defaultAdmin Unused.
    function initialize(
        IERC20 stakingAsset,
        address rollupRegistry,
        address rewardsVault,
        address core_,
        address stakingProviderRegistry_,
        address defaultAdmin
    ) external override {
        stakingAsset;
        rollupRegistry;
        rewardsVault;
        core = core_;
        _stakingProviderRegistry = IStakingProviderRegistry(stakingProviderRegistry_);
        defaultAdmin;
        return;
    }

    /// @notice Records a stake request.
    /// @param amount The amount to stake.
    function stake(uint256 amount) external override {
        lastStakeAmount = amount;
        _stakedAmount += amount;
        ++stakeCalls;
    }

    /// @notice Records an unstake request.
    /// @param amount The amount to unstake.
    function unstake(uint256 amount) external override {
        lastUnstakeAmount = amount;
        if (amount != 0 && _stakedAmount > amount - 1) {
            _stakedAmount -= amount;
        }
        ++unstakeCalls;
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
        return StakingState({ stakedAmount: _stakedAmount, pendingUnstakeAmount: 0, withdrawableAmount: 0 });
    }

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256 stakedTotal) {
        return _stakedAmount;
    }

    /// @inheritdoc IStakingManager
    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return _providerConfig;
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function pendingUnstakes() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getSlashingDelta() external pure override returns (uint256 slashingDelta) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getClaimableRewards() external pure override returns (uint256 claimableRewards) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getUnstakedFunds() external pure override returns (uint256 received) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function harvestRewards() external pure override returns (uint256 harvested) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getActivatedAttesterCount() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getPendingUnstakeCount() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function isUnstakePending(address) external pure override returns (bool) {
        return false;
    }

    /// @inheritdoc IStakingManager
    function cleanActivatedAttesters() external pure override {
        // No-op for mock
        return;
    }
}
