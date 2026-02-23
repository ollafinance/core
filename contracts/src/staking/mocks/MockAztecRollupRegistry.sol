// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IMockAztecRollupRegistry } from "src/staking/mocks/IMockAztecRollupRegistry.sol";

/// @title MockRollupRegistry
/// @notice Mock implementation of the Aztec Rollup Registry for testing.
/// @dev Always returns the canonical rollup address set at construction.
/// @author Olla Core contributors
contract MockAztecRollupRegistry is IMockAztecRollupRegistry {
    /// @dev The canonical rollup address.
    address private _canonicalRollup;

    /// @dev The governance address.
    address private _governance;

    /// @notice Constructs the MockAztecRollupRegistry.
    /// @param canonicalRollup_ The address of the canonical rollup.
    constructor(address canonicalRollup_) {
        _canonicalRollup = canonicalRollup_;
        _governance = msg.sender;
    }

    /// @inheritdoc IMockAztecRollupRegistry
    function setCanonicalRollup(address canonicalRollup_) external override {
        _canonicalRollup = canonicalRollup_;
    }

    /// @notice Returns the canonical (latest) rollup address.
    /// @return The address of the canonical rollup contract.
    function getCanonicalRollup() external view override returns (address) {
        return _canonicalRollup;
    }

    /// @notice Returns the governance address.
    /// @return The address of the governance contract.
    function getGovernance() external view override returns (address) {
        return _governance;
    }

    /// @notice Sets the governance address (for testing).
    /// @param governance_ The new governance address.
    function _setGovernance(address governance_) internal {
        _governance = governance_;
    }
}
