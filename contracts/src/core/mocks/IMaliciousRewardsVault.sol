// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";

/// @title IMaliciousRewardsVault
/// @notice Test-only interface for configuring reentrancy behavior on a rewards vault.
/// @author Olla Core contributors
interface IMaliciousRewardsVault is IRewardsVault {
    /// @notice Thrown when initialize is called (not allowed in mock).
    error MaliciousRewardsVault__NoInitializer();

    /// @notice Configure the call to perform during a reentrancy attempt.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @param enabled Whether reentrancy is enabled.
    function configureReentry(address target, bytes calldata data, bool enabled) external;

    /// @notice Returns the cumulative amount passed to `recordRewards`.
    /// @return The cumulative amount.
    function totalReceived() external view returns (uint256);
}
