// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

/// @title MockStakingManager
/// @notice Minimal staking manager mock for message routing tests.
/// @author Olla Core contributors
contract MockStakingManager is IStakingManager {
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

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
    function getStakingState() external view override returns (StakingState memory) {
        return StakingState({ stakedAmount: _stakedAmount, pendingUnstakeAmount: 0, withdrawableAmount: 0 });
    }

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256 totalStaked) {
        return _stakedAmount;
    }

    /// @notice No-op initializer for interface compatibility.
    /// @param stakingAsset Unused.
    /// @param rollupRegistry Unused.
    /// @param rewardsVault Unused.
    /// @param core Unused.
    /// @param providerAdmin Unused.
    /// @param providerRewardsRecipient Unused.
    /// @param defaultAdmin Unused.
    function initialize(
        IERC20 stakingAsset,
        address rollupRegistry,
        address rewardsVault,
        address core,
        address providerAdmin,
        address providerRewardsRecipient,
        address defaultAdmin
    ) external pure override {
        stakingAsset;
        rollupRegistry;
        rewardsVault;
        core;
        providerAdmin;
        providerRewardsRecipient;
        defaultAdmin;
        return;
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function getClaimableRewards() external pure override returns (uint256 claimableRewards) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getSlashingDelta() external pure override returns (uint256 slashingDelta) {
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
    function getQueueLength() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getProviderConfig() external pure override returns (ProviderConfig memory) {
        return ProviderConfig({ admin: address(0), rewardsRecipient: address(0) });
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

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL NON-VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function addKeysToProvider(KeyStore[] calldata) external pure override {
        // No-op for mock
        return;
    }

    /// @inheritdoc IStakingManager
    function dripQueue(uint256) external pure override {
        // No-op for mock
        return;
    }

    /// @inheritdoc IStakingManager
    function setProviderRewardsRecipient(address) external pure override {
        // No-op for mock
        return;
    }

    /// @inheritdoc IStakingManager
    function cleanActivatedAttesters() external pure override {
        // No-op for mock
        return;
    }
}
