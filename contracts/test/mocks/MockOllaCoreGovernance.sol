// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

/// @title MockOllaCoreGovernance
/// @notice Minimal mock for governance lookup via IOllaCore.
contract MockOllaCoreGovernance {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address public governance;
    address public pendingGovernance;

    constructor(address governance_, address pendingGovernance_) {
        governance = governance_;
        pendingGovernance = pendingGovernance_;
    }

    function setGovernance(address governance_) external {
        governance = governance_;
    }

    function setPendingGovernance(address pendingGovernance_) external {
        pendingGovernance = pendingGovernance_;
    }
}
