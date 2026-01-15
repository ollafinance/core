// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;
import {IStakingManager} from "src/interfaces/IStakingManager.sol";

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

    /// @notice Simulated total staked amount.
    uint256 private _totalStaked;

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Records a stake request.
    /// @param amount The amount to stake.
    function stake(uint256 amount) external override {
        lastStakeAmount = amount;
        _totalStaked += amount;
        ++stakeCalls;
    }

    /// @notice Records an unstake request.
    /// @param amount The amount to unstake.
    function unStake(uint256 amount) external override {
        lastUnstakeAmount = amount;
        if (_totalStaked >= amount) {
            _totalStaked -= amount;
        }
        ++unstakeCalls;
    }

    /// @inheritdoc IStakingManager
    function addKeysToProvider(KeyStore[] calldata) external override {
        // No-op for mock
    }

    /// @inheritdoc IStakingManager
    function dripQueue(uint256) external override {
        // No-op for mock
    }

    /// @inheritdoc IStakingManager
    function setProviderRewardsRecipient(address) external override {
        // No-op for mock
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256) {
        return _totalStaked;
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function getUnstakedFunds()
        external
        pure
        override
        returns (uint256 received)
    {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function harvestRewards()
        external
        pure
        override
        returns (uint256 harvested)
    {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getPendingUnstakes() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getQueueLength() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getProviderConfig()
        external
        pure
        override
        returns (ProviderConfig memory)
    {
        return
            ProviderConfig({admin: address(0), rewardsRecipient: address(0)});
    }

    /// @inheritdoc IStakingManager
    function getActiveValidatorCount()
        external
        pure
        override
        returns (uint256)
    {
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
}
