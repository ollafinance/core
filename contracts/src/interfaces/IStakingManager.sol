// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title IStakingManager
/// @notice Interface for OllaCore stake/unstake messaging.
/// @author Olla Core contributors
interface IStakingManager {
    /// @notice Stakes assets with the staking provider.
    /// @param amount The amount to stake.
    function stake(uint256 amount) external;

    /// @notice Initiates an unstake with the staking provider.
    /// @param amount The amount to unstake.
    function unStake(uint256 amount) external;
}
