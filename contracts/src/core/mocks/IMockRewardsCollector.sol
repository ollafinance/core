// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IRewardsCollector } from "src/core/interfaces/IRewardsCollector.sol";

/// @title IMockRewardsCollector
/// @notice Interface for MockRewardsCollector test helper contract.
/// @dev Extends IRewardsCollector with test-specific functions.
/// @author Olla Core contributors
interface IMockRewardsCollector is IRewardsCollector {
    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when hook should fail (for testing).
    error MockRewardsCollector__HookFailed();

    /// @notice Thrown when initialize is called (not allowed in mock).
    error MockRewardsCollector__NoInitializer();

    /*//////////////////////////////////////////////////////////////
                          TEST HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets whether recordBalance should fail (test helper).
    /// @param shouldFail Whether the hook should revert.
    function setHookShouldFail(bool shouldFail) external;

    /// @notice Returns total funds received via recordBalance (test helper).
    /// @return The total amount received.
    function totalReceived() external view returns (uint256);
}
