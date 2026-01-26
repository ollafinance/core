// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

/// @title IMaliciousAztec
/// @notice Interface for MaliciousAztec test helper.
/// @author Olla Core contributors
interface IMaliciousAztec {
    /// @notice Configure a reentrancy attempt during transferFrom.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @param enabled Whether to enable the reentrancy attempt.
    function configureReentry(address target, bytes calldata data, bool enabled) external;

    /// @notice Set allowance from this token contract to itself.
    /// @param amount The allowance amount.
    function setSelfAllowance(uint256 amount) external;
}
