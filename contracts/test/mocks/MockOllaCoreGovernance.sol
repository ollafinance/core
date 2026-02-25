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
}
