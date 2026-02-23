// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

/// @title IMaliciousAztec
/// @notice Interface for MaliciousAztec test helper.
/// @author Olla Core contributors
interface IMaliciousAztec {
    /// @notice Configure a reentrancy attempt during transferFrom.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @param enabled Whether to enable the reentrancy attempt.
    function configureReentry(address target, bytes calldata data, bool enabled) external;

    /// @notice Configure a reentrancy attempt during transfer.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @param enabled Whether to enable the reentrancy attempt.
    function configureTransferReentry(address target, bytes calldata data, bool enabled) external;

    /// @notice Set the number of transfer calls to skip before triggering re-entry.
    /// @param count The number of transfers to skip (0 = fire on first transfer).
    function setTransferReentrySkipCount(uint256 count) external;

    /// @notice Set allowance from this token contract to itself.
    /// @param amount The allowance amount.
    function setSelfAllowance(uint256 amount) external;
}
