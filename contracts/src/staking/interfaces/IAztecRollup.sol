// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AttesterView, DepositArgs } from "src/staking/libraries/AztecTypes.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

/// @title IAztecRollup
/// @notice Minimal interface for Aztec rollup
/// @dev Following Aztec interfaces are used: IStaking and IRollup
///
/// ## MAINTENANCE REQUIREMENTS
///
/// When adding a function to this interface, make sure to also add a test in:
///    olla-core/contracts/test/integration/AztecInterfaceCompatibility.integration.t.sol
///
/// ## Why use a custom minimal interface instead of official?
/// - Reduces attack surface by forcing less functions to be used (only necessary ones)
/// - Avoids coupling to Aztec's internal types (StakingQueueConfig, GSE, etc.)
/// - Simplifies mock implementations for testing
///
/// @author Olla Core contributors
interface IAztecRollup {
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
    /// @dev taken from IStaking
    /// @param _attester The attester address to withdraw stake for.
    /// @param _recipient The address that will receive the stake.
    /// @return True if withdrawal was successfully initiated.
    function initiateWithdraw(address _attester, address _recipient) external returns (bool);

    /// @notice Finalizes withdrawal for a attester.
    /// @dev taken from IStaking
    /// @param _attester The attester address completing withdrawal.
    function finalizeWithdraw(address _attester) external;

    /// @notice Claims sequencer rewards for a given coinbase address.
    /// @dev taken from IRollupCore
    /// @param _coinbase The address to claim rewards for.
    /// @return The amount of rewards claimed.
    function claimSequencerRewards(address _coinbase) external returns (uint256);

    /// @notice Returns the activation threshold amount.
    /// @dev taken from IStaking
    /// @return The stake amount required per attester.
    function getActivationThreshold() external view returns (uint256);

    /// @notice Returns the attester view for a given attester.
    /// @dev taken from IStaking
    /// @param _attester The attester address to query.
    /// @return The attester view struct.
    function getAttesterView(address _attester) external view returns (AttesterView memory);

    /// @notice Returns the pending sequencer rewards for a given coinbase-address.
    /// @dev taken from IRollup
    /// @param _coinbase The coinbase address to query.
    /// @return The amount of pending rewards.
    function getSequencerRewards(address _coinbase) external view returns (uint256);

    /// @notice Returns the number of validators in the entry queue.
    /// @dev taken from IStaking
    /// @return The entry queue length.
    function getEntryQueueLength() external view returns (uint256);

    /// @notice Returns the deposit args for a validator at the given queue index.
    /// @dev taken from IStaking
    /// @param _index The queue index.
    /// @return The deposit args for the queued validator.
    function getEntryQueueAt(uint256 _index) external view returns (DepositArgs memory);
}
