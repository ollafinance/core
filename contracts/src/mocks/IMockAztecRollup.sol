// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.24 <0.9.0;

import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {Exit, Status} from "src/libraries/AztecTypes.sol";
import {G1Point, G2Point} from "src/libraries/BN254Lib.sol";

/// @title IMockAztecRollup
/// @notice Interface for MockAztecRollup test helper contract.
/// @dev Extends IAztecStaking with test-specific functions.
/// @author Olla Core contributors
interface IMockAztecRollup {
    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a validator deposits stake.
    /// @param attester The attester address.
    /// @param withdrawer The withdrawer address.
    /// @param publicKeyInG1 The public key in G1.
    /// @param publicKeyInG2 The public key in G2.
    /// @param proofOfPossession The proof of possession.
    /// @param amount The deposit amount.
    event Deposit(
        address indexed attester,
        address indexed withdrawer,
        G1Point publicKeyInG1,
        G2Point publicKeyInG2,
        G1Point proofOfPossession,
        uint256 amount
    );

    /// @notice Emitted when a withdrawal is initiated.
    /// @param attester The attester address.
    /// @param recipient The recipient address.
    /// @param amount The withdrawal amount.
    event WithdrawInitiated(address indexed attester, address indexed recipient, uint256 indexed amount);

    /// @notice Emitted when a withdrawal is finalized.
    /// @param attester The attester address.
    /// @param recipient The recipient address.
    /// @param amount The withdrawal amount.
    event WithdrawFinalized(address indexed attester, address indexed recipient, uint256 indexed amount);

    /// @notice Emitted when rewards are claimed.
    /// @param sequencer The sequencer address.
    /// @param recipient The recipient address.
    /// @param amount The rewards amount.
    event RewardsClaimed(address indexed sequencer, address indexed recipient, uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not the withdrawer.
    error MockAztecRollup__NotWithdrawer();

    /// @notice Thrown when attester is already exiting.
    error MockAztecRollup__AlreadyExiting();

    /// @notice Thrown when attester is not exiting.
    error MockAztecRollup__NotExiting();

    /// @notice Thrown when initiateWithdraw was not called.
    error MockAztecRollup__InitiateWithdrawNeeded();

    /// @notice Thrown when exit is not ready for finalization.
    error MockAztecRollup__NotReady();

    /*//////////////////////////////////////////////////////////////
                         EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits stake for a new validator.
    /// @param attester The attester address.
    /// @param withdrawer The withdrawer address.
    /// @param publicKeyInG1 The public key in G1.
    /// @param publicKeyInG2 The public key in G2.
    /// @param proofOfPossession The proof of possession.
    /// @param onCanonical Whether to stake on canonical chain.
    function deposit(
        address attester,
        address withdrawer,
        G1Point memory publicKeyInG1,
        G2Point memory publicKeyInG2,
        G1Point memory proofOfPossession,
        bool onCanonical
    ) external;

    /// @notice Initiates withdrawal for a validator.
    /// @param attester The attester address.
    /// @param recipient The recipient address.
    /// @return success Whether the withdrawal was initiated.
    function initiateWithdraw(address attester, address recipient) external returns (bool success);

    /// @notice Finalizes withdrawal for a validator.
    /// @param attester The attester address.
    function finalizeWithdraw(address attester) external;

    /// @notice Claims sequencer rewards.
    /// @param recipient The recipient address.
    /// @return amount The amount of rewards claimed.
    function claimSequencerRewards(address recipient) external returns (uint256 amount);

    /// @notice Sets pending rewards for a sequencer (test helper).
    /// @param sequencer The sequencer address.
    /// @param amount The rewards amount.
    function setRewards(address sequencer, uint256 amount) external;

    /// @notice Sets the activation threshold (test helper).
    /// @param threshold The new activation threshold.
    function setActivationThreshold(uint256 threshold) external;

    /// @notice Sets an exit as ready for finalization (test helper).
    /// @param attester The attester address.
    /// @param exitableAt The timestamp when exit becomes finalizable.
    function setExitReady(address attester, uint256 exitableAt) external;

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the staking asset address.
    /// @return The IERC20 staking asset.
    function STAKING_ASSET() external view returns (IERC20);

    /// @notice Returns the stake amount for an attester.
    /// @param attester The attester address.
    /// @return The stake amount.
    function stakes(address attester) external view returns (uint256);

    /// @notice Returns the withdrawer for an attester.
    /// @param attester The attester address.
    /// @return The withdrawer address.
    function withdrawers(address attester) external view returns (address);

    /// @notice Returns the pending rewards for a sequencer.
    /// @param sequencer The sequencer address.
    /// @return The pending rewards amount.
    function pendingRewards(address sequencer) external view returns (uint256);

    /// @notice Returns the exit record for an attester.
    /// @param attester The attester address.
    /// @return The exit record.
    function getExit(address attester) external view returns (Exit memory);

    /// @notice Returns the status of an attester.
    /// @param attester The attester address.
    /// @return The attester status.
    function getStatus(address attester) external view returns (Status);

    /// @notice Returns the activation threshold.
    /// @return The activation threshold amount.
    function getActivationThreshold() external view returns (uint256);

    /// @notice Returns the sequencer rewards for an address.
    /// @param sequencer The sequencer address.
    /// @return The sequencer rewards amount.
    function getSequencerRewards(address sequencer) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the active attester count.
    /// @return The count of active attesters.
    function getActiveAttesterCount() external pure returns (uint256);
}
