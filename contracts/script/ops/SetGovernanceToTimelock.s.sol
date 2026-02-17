// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { TimelockController } from "@oz/governance/TimelockController.sol";

import { OllaCore } from "src/core/OllaCore.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title SetGovernanceToTimelock
/// @notice Updates OllaCore governance address to the timelock.
contract SetGovernanceToTimelock is BaseScript {
    function run() external {
        uint256 pk = _privateKey();
        address caller = vm.addr(pk);
        address timelock =
            _addrOrDeployment("TIMELOCK", "TimelockController", "TIMELOCK missing: set TIMELOCK or deploy timelock");
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        bytes32 adminRole = bytes32(0);

        vm.startBroadcast(pk);

        if (AccessControlUpgradeable(core).hasRole(adminRole, caller)) {
            OllaCore(core).setGovernance(timelock);
        } else {
            TimelockController timelockController = TimelockController(payable(timelock));
            bytes memory payload = abi.encodeCall(OllaCore.setGovernance, (timelock));
            bytes32 predecessor = bytes32(0);
            bytes32 salt = vm.envOr("TIMELOCK_SALT", bytes32(0));
            uint256 delay = timelockController.getMinDelay();

            timelockController.schedule(core, 0, payload, predecessor, salt, delay);
            timelockController.execute(core, 0, payload, predecessor, salt);
        }

        vm.stopBroadcast();
    }
}
