// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

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

// Configuration of an attester (checkpoint producer).
// Stores the BN254 G1 public key registered on the instance and the
// withdrawer address that can initiate and control withdrawals for the attester.
struct AttesterConfig {
    G1Point publicKey;
    address withdrawer;
}

// Read-only view of an attester's full state: current status, effective stake
// balance, pending exit details, and configuration.
struct AttesterView {
    Status status;
    uint256 effectiveBalance;
    Exit exit;
    AttesterConfig config;
}

/// @notice Arguments for a queued validator deposit (mirrors Aztec's StakingQueue.DepositArgs).
/// @param attester The address that will act as the attester.
/// @param withdrawer The address that can withdraw the stake.
/// @param publicKeyInG1 The G1 point of the BLS public key.
/// @param publicKeyInG2 The G2 point of the BLS public key.
/// @param proofOfPossession Proof of possession.
/// @param moveWithLatestRollup Whether to follow rollup upgrades.
struct DepositArgs {
    address attester;
    address withdrawer;
    G1Point publicKeyInG1;
    G2Point publicKeyInG2;
    G1Point proofOfPossession;
    bool moveWithLatestRollup;
}
