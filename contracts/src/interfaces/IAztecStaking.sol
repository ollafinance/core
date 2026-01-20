// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { AttesterView } from "src/libraries/AztecTypes.sol";
import { G1Point, G2Point } from "src/libraries/BN254Lib.sol";

/// @title IAztecStaking
/// @notice Minimal interface for Aztec rollup staking operations.
/// @dev Mirrors the IStaking interface from Aztec contracts.
///
/// ## MAINTENANCE REQUIREMENTS
///
/// This interface MUST be kept in sync with the official Aztec IStaking interface:
/// - File: `contracts/dependencies/aztec-contracts-*/src/core/interfaces/IStaking.sol`
/// - Verify compatibility by running: `forge test --match-contract AztecInterfaceCompatibilityTest`
///
/// When upgrading Aztec contracts:
/// 1. Check for breaking changes in the official interface
/// 2. Update this interface if needed
/// 3. Verify compatibility tests pass
///
/// ## TRADE-OFF
///
/// Why use a custom minimal interface instead of official IStaking?
/// - Reduces attack surface (only 4 functions vs 30+)
/// - Avoids coupling to Aztec's internal types (StakingQueueConfig, GSE, etc.)
/// - Simplifies mock implementations for testing
///
/// Risk: Breaking changes in Aztec contracts could cause silent failures.
/// Mitigation: Automated compatibility tests (Phase 1).
/// @author Olla Core contributors
interface IAztecStaking {
    /// @notice Deposits stake for a new attester.
    /// @param _attester The address that will act as the attester.
    /// @param _withdrawer The address that can withdraw the stake.
    /// @param _publicKeyInG1 The G1 point of the BLS public key.
    /// @param _publicKeyInG2 The G2 point of the BLS public key.
    /// @param _proofOfPossession Proof that G1 and G2 keys share the same secret.
    /// @param _moveWithLatestRollup Whether to follow rollup upgrades.
    function deposit(
        address _attester,
        address _withdrawer,
        G1Point memory _publicKeyInG1,
        G2Point memory _publicKeyInG2,
        G1Point memory _proofOfPossession,
        bool _moveWithLatestRollup
    ) external;

    /// @notice Initiates withdrawal for a attester.
    /// @param _attester The attester address to withdraw stake for.
    /// @param _recipient The address that will receive the stake.
    /// @return True if withdrawal was successfully initiated.
    function initiateWithdraw(address _attester, address _recipient) external returns (bool);

    /// @notice Finalizes withdrawal for a attester.
    /// @param _attester The attester address completing withdrawal.
    function finalizeWithdraw(address _attester) external;

    /// @notice Returns the activation threshold amount.
    /// @return The stake amount required per attester.
    function getActivationThreshold() external view returns (uint256);

    function getAttesterView(address _attester) external view returns (AttesterView memory);
}
