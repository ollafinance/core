// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IAztecRollupRegistry } from "src/interfaces/IAztecRollupRegistry.sol";

/// @title MockRollupRegistry
/// @notice Mock implementation of the Aztec Rollup Registry for testing.
/// @dev Always returns the canonical rollup address set at construction.
/// @author Olla Core contributors
contract MockAztecRollupRegistry is IAztecRollupRegistry {
    /// @dev The canonical rollup address.
    address private _canonicalRollup;

    /// @dev The governance address.
    address private _governance;

    /// @param canonicalRollup_ The address of the canonical rollup.
    constructor(address canonicalRollup_) {
        _canonicalRollup = canonicalRollup_;
        _governance = msg.sender;
    }

    /// @inheritdoc IAztecRollupRegistry
    function getCanonicalRollup() external view override returns (address) {
        return _canonicalRollup;
    }

    /// @inheritdoc IAztecRollupRegistry
    function getRollup(uint256) external view override returns (address) {
        // For simplicity, always return the canonical rollup regardless of version
        return _canonicalRollup;
    }

    /// @inheritdoc IAztecRollupRegistry
    function getGovernance() external view override returns (address) {
        return _governance;
    }

    /// @notice Sets the canonical rollup address (for testing).
    /// @param canonicalRollup_ The new canonical rollup address.
    function _setCanonicalRollup(address canonicalRollup_) internal {
        _canonicalRollup = canonicalRollup_;
    }

    /// @notice Sets the governance address (for testing).
    /// @param governance_ The new governance address.
    function _setGovernance(address governance_) internal {
        _governance = governance_;
    }
}
