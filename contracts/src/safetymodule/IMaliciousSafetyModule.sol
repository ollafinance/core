// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

/// @title IMaliciousSafetyModule
/// @notice Interface for MaliciousSafetyModule test helper.
/// @author Olla Core contributors
interface IMaliciousSafetyModule {
    /// @notice Configure re-entry target and calldata.
    /// @param target The contract to call during re-entry.
    /// @param data The calldata to use.
    function setReentry(address target, bytes calldata data) external;

    /// @notice Enable or disable re-entry on checkAccountingLiveness.
    /// @param enabled Whether to enable the reentrancy attempt.
    function setReenterOnCheckAccountingLiveness(bool enabled) external;
}
