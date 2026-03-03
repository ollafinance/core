// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";

/// @title IMockRewardsAccumulator
/// @notice Interface for MockRewardsAccumulator test helper contract.
/// @dev Extends IRewardsAccumulator with test-specific functions.
/// @author Olla Core contributors
interface IMockRewardsAccumulator is IRewardsAccumulator {
    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when hook should fail (for testing).
    error MockRewardsAccumulator__HookFailed();

    /// @notice Thrown when initialize is called (not allowed in mock).
    error MockRewardsAccumulator__NoInitializer();

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
