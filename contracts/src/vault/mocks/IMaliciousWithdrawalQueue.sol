// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

/// @title IMaliciousWithdrawalQueue
/// @notice Interface for MaliciousWithdrawalQueue test helper.
/// @author Olla Core contributors
interface IMaliciousWithdrawalQueue {
    /// @notice Configure the call to perform during a reentrancy attempt.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    function setReentry(address target, bytes calldata data) external;

    /// @notice Enable/disable reentrancy during requestWithdrawal.
    /// @param enabled Whether to enable reentrancy.
    function setReenterOnRequest(bool enabled) external;

    /// @notice Enable/disable reentrancy during claimWithdrawal.
    /// @param enabled Whether to enable reentrancy.
    function setReenterOnClaim(bool enabled) external;

    /// @notice Enable/disable reentrancy during finalizeWithdrawals.
    /// @param enabled Whether to enable reentrancy.
    function setReenterOnFinalize(bool enabled) external;
}
