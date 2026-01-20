// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

/// @title AztecTypes
/// @notice Types for Aztec staking compatibility.
/// @dev These types mirror the Aztec contracts for interoperability.
/// @author Olla Core contributors

/// @notice Wrapper type for timestamps.
type Timestamp is uint256;

/// @notice Attester status in the staking system.
enum Status {
    NONE, // Not registered
    VALIDATING, // Activated attester
    ZOMBIE, // Slashed, has funds but not validating
    EXITING // In withdrawal process
}

/// @notice Represents a attester's exit from the staking system.
/// @param withdrawalId Unique identifier for this withdrawal.
/// @param amount The amount of stake being withdrawn.
/// @param exitableAt Timestamp when the stake becomes withdrawable.
/// @param recipientOrWithdrawer Address for funds or initiating withdrawal.
/// @param isRecipient True if recipientOrWithdrawer is the recipient.
/// @param exists True if this exit record exists.
struct Exit {
    uint256 withdrawalId;
    uint256 amount;
    Timestamp exitableAt;
    address recipientOrWithdrawer;
    bool isRecipient;
    bool exists;
}
