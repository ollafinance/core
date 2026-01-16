// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

/// @title IRollupRegistry
/// @notice Minimal interface for the Aztec Rollup Registry contract.
/// @dev This interface provides access to rollup addresses by version.
///      The registry is the source of truth for which rollup contract to interact with.
///
/// ## MAINTENANCE REQUIREMENTS
///
/// This interface should be kept in sync with the official Aztec Registry interface.
/// When upgrading Aztec contracts, verify compatibility with the official interface.
///
/// @author Olla Core contributors
interface IAztecRollupRegistry {
    /// @notice Returns the canonical (latest) rollup address.
    /// @return The address of the canonical rollup contract.
    function getCanonicalRollup() external view returns (address);

    /// @notice Returns the rollup address for a specific version.
    /// @param version The rollup version number.
    /// @return The address of the rollup contract for that version.
    function getRollup(uint256 version) external view returns (address);

    /// @notice Returns the governance address.
    /// @return The address of the governance contract.
    function getGovernance() external view returns (address);
}
