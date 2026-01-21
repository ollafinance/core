// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

/// @title IAztecRollupRegistry
/// @notice Minimal interface for the Aztec Rollup Registry contract.
/// @dev Mirrors the IRegistry interface from Aztec contracts.
///
/// ## MAINTENANCE REQUIREMENTS
///
/// *When adding a function to this interface, make sure to also add a test in:
///     olla-core/contracts/test/integration/AztecInterfaceCompatibility.t.sol
///
/// ## TRADE-OFF
///
/// Why use a custom minimal interface instead of official IStaking?
/// - Reduces attack surface (only 4 functions vs 30+)
/// - Avoids coupling to Aztec's internal types (StakingQueueConfig, GSE, etc.)
/// - Simplifies mock implementations for testing
///
/// @author Olla Core contributors
interface IAztecRollupRegistry {
    /// @notice Returns the canonical (latest) rollup address.
    /// @return The address of the canonical rollup contract.
    function getCanonicalRollup() external view returns (address);

    /// @notice Returns the governance address.
    /// @return The address of the governance contract.
    function getGovernance() external view returns (address);
}
