// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";

/// @title IMockRewardsVault
/// @notice Interface for MockRewardsVault test helper contract.
/// @dev Extends IRewardsVault with test-specific functions.
/// @author Olla Core contributors
interface IMockRewardsVault is IRewardsVault {
    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when hook should fail (for testing).
    error MockRewardsVault__HookFailed();

    /// @notice Thrown when initialize is called (not allowed in mock).
    error MockRewardsVault__NoInitializer();

    /*//////////////////////////////////////////////////////////////
                          TEST HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets whether recordRewards should fail (test helper).
    /// @param shouldFail Whether the hook should revert.
    function setHookShouldFail(bool shouldFail) external;

    /// @notice Returns total funds received via recordRewards (test helper).
    /// @return The total amount received.
    function totalReceived() external view returns (uint256);
}
