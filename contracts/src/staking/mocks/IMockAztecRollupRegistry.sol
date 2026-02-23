// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IAztecRollupRegistry } from "src/staking/interfaces/IAztecRollupRegistry.sol";

/// @title IMockAztecRollupRegistry
/// @notice Interface for MockAztecRollupRegistry test helper contract.
/// @dev Extends IAztecRollupRegistry with test-specific functions.
/// @author Olla Core contributors
interface IMockAztecRollupRegistry is IAztecRollupRegistry {
    /// @notice Sets the canonical rollup address (for testing).
    /// @param canonicalRollup The new canonical rollup address.
    function setCanonicalRollup(address canonicalRollup) external;
}
