// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { OllaCore } from "src/core/OllaCore.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title SetGovernanceToTimelock
/// @notice Updates OllaCore governance address to the timelock.
contract SetGovernanceToTimelock is BaseScript {
    function run() external {
        uint256 pk = _privateKey();
        address timelock =
            _addrOrDeployment("TIMELOCK", "TimelockController", "TIMELOCK missing: set TIMELOCK or deploy timelock");
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");

        vm.startBroadcast(pk);
        OllaCore(core).setGovernance(timelock);
        vm.stopBroadcast();
    }
}
