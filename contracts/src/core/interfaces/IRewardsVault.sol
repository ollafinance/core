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

    /// @notice Emitted when excess funds are detected.
    /// @param amount The amount of excess funds.
    event ExcessFundsDetected(uint256 indexed amount);

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

    /// @notice Thrown when there is a balance mismatch.
    error RewardsVault__BalanceMismatch();

    /// @notice Thrown when caller is not authorized core.
    error RewardsVault__UnauthorizedCore(address caller);

    /*//////////////////////////////////////////////////////////////
                                 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the vault when deployed behind a proxy.
    /// @param rewardsToken_ The rewards token address.
    /// @param core_ The core contract address.
    /// @param defaultAdmin_ The default admin for role management.
    function initialize(IERC20 rewardsToken_, address core_, address defaultAdmin_) external;

    /// @notice Hook called after rewards are transferred to the vault. Updates internal accounting.
    /// @dev Only callable by the configured core address.
    /// @param expectedRewards The amount of rewards transferred.
    function recordRewards(uint256 expectedRewards) external;

    /// @notice Withdraws all available rewards to the core contract.
    /// @dev Only callable by the configured core address.
    function withdrawToCore() external;

    // TODO: evaluate to replace with ERC-balance?
    /// @notice Returns the current available funds.
    /// @return The balance of funds held in the vault.
    function balance() external view returns (uint256);

    /// @notice Returns the core address.
    /// @return The core contract address.
    function core() external view returns (address);

    /// @notice Returns the rewards token address.
    /// @return The ERC20 token address for rewards.
    function rewardsToken() external view returns (IERC20);

    /// @notice Returns the latest recorded rewards amount.
    /// @return The latest recorded rewards amount.
    function latestRecordedRewardsAmount() external view returns (uint256);
}
