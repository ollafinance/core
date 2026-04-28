// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

/// @title MockOllaCoreGovernance
/// @notice Minimal mock for owner lookup via Ownable on OllaCore.
contract MockOllaCoreGovernance {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    /// @notice No-op IFinalizationCallback hook so this mock can stand in as the vault for
    ///         WithdrawalQueue tests that exercise the per-request finalization callback.
    function onWithdrawalFinalized(uint256, uint256) external { }
}
