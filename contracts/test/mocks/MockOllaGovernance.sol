// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

/// @notice Minimal mock for OllaGovernance used in OllaCore tests.
///         By default, treasury() returns the mock's own address so that
///         existing assertions checking balances at `governance` keep working.
contract MockOllaGovernance {
    address private _treasury;

    function treasury() external view returns (address) {
        return _treasury == address(0) ? address(this) : _treasury;
    }

    function setTreasury(address newTreasury) external {
        _treasury = newTreasury;
    }
}
