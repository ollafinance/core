// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

/// @title IRewardsVault
/// @notice Interface for rewards and fee management vault.
/// @author Olla Core contributors
interface IRewardsVault {
    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when rewards are recorded.
    /// @param amount The amount of rewards recorded.
    event RewardsRecorded(uint256 indexed amount);

    /// @notice Emitted when rewards are withdrawn to core.
    /// @param amount The amount of rewards withdrawn.
    event RewardsWithdrawn(uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not authorized.
    error RewardsVault__Unauthorized(address caller);

    /// @notice Thrown when address is zero.
    error RewardsVault__ZeroAddress(string param);

    /// @notice Thrown when insufficient balance for withdrawal.
    error RewardsVault__InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Thrown when amount is zero.
    error RewardsVault__ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hook called after receiving funds from external sources.
    /// @dev Can be called by StakingManager or AztecRollup directly after reward transfer.
    /// @param amount The amount of funds received.
    function postReceiveFundsHook(uint256 amount) external;

    /// @notice Withdraws all available rewards to the core contract.
    /// @dev Only callable by addresses with CORE_ROLE.
    function withdrawToCore() external;

    /// @notice Returns the current available funds.
    /// @return The balance of funds held in the vault.
    function balance() external view returns (uint256);

    /// @notice Returns the core address.
    /// @return The core contract address.
    function core() external view returns (address);

    /// @notice Returns the rewards token address.
    /// @return The ERC20 token address for rewards.
    function rewardsToken() external view returns (IERC20);
}
