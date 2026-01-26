// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IMockAztecRollup } from "src/mocks/IMockAztecRollup.sol";

/// @title IMaliciousAztecRollup
/// @notice Test-only interface for configuring reentrancy behavior on a mock rollup.
/// @author Olla Core contributors
interface IMaliciousAztecRollup is IMockAztecRollup {
    /// @notice Configure the call to perform during a reentrancy attempt.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    function setReentry(address target, bytes calldata data) external;

    /// @notice Enable/disable a reentrancy attempt during `deposit`.
    /// @param enabled Whether reentrancy is enabled.
    function setReenterOnDeposit(bool enabled) external;

    /// @notice Enable/disable a reentrancy attempt during `initiateWithdraw`.
    /// @param enabled Whether reentrancy is enabled.
    function setReenterOnInitiateWithdraw(bool enabled) external;

    /// @notice Enable/disable a reentrancy attempt during `finalizeWithdraw`.
    /// @param enabled Whether reentrancy is enabled.
    function setReenterOnFinalizeWithdraw(bool enabled) external;

    /// @notice Enable/disable a reentrancy attempt during `claimSequencerRewards`.
    /// @param enabled Whether reentrancy is enabled.
    function setReenterOnClaimSequencerRewards(bool enabled) external;
}
