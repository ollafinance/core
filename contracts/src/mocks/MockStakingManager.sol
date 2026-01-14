// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IStakingManager } from "src/interfaces/IStakingManager.sol";

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

    /// @notice Records a stake request.
    /// @param amount The amount to stake.
    function stake(uint256 amount) external override {
        lastStakeAmount = amount;
        ++stakeCalls;
    }

    /// @notice Records an unstake request.
    /// @param amount The amount to unstake.
    function unStake(uint256 amount) external override {
        lastUnstakeAmount = amount;
        ++unstakeCalls;
    }
}
