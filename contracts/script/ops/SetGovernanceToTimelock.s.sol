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
        address timelock = vm.envOr("TIMELOCK", address(0));
        if (timelock == address(0)) {
            timelock = _addrOrDeployment(
                "TIMELOCK", "TimelockController", "TIMELOCK missing: set TIMELOCK or deploy timelock"
            );
        }
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        bytes32 adminRole = bytes32(0);
        bool proposedViaTimelock = false;
        bytes32 proposalSalt = vm.envOr("TIMELOCK_SALT", bytes32(0));

        vm.startBroadcast(pk);

        if (AccessControlUpgradeable(core).hasRole(adminRole, caller)) {
            OllaCore(core).proposeGovernance(timelock);
        } else {
            TimelockController timelockController = TimelockController(payable(timelock));
            bytes memory payload = abi.encodeCall(OllaCore.proposeGovernance, (timelock));
            bytes32 predecessor = bytes32(0);
            uint256 delay = timelockController.getMinDelay();

            timelockController.schedule(core, 0, payload, predecessor, proposalSalt, delay);
            if (delay == 0) {
                timelockController.execute(core, 0, payload, predecessor, proposalSalt);
            }
            proposedViaTimelock = true;
        }

        require(OllaCore(core).pendingGovernance() == timelock, "pending governance must be timelock");

        {
            TimelockController timelockController = TimelockController(payable(timelock));
            bytes memory acceptPayload = abi.encodeCall(OllaCore.acceptGovernance, ());
            uint256 delay = timelockController.getMinDelay();
            bytes32 acceptPredecessor = proposedViaTimelock
                ? timelockController.hashOperation(
                    core, 0, abi.encodeCall(OllaCore.proposeGovernance, (timelock)), bytes32(0), proposalSalt
                )
                : bytes32(0);
            bytes32 acceptSalt = vm.envOr("TIMELOCK_ACCEPT_SALT", bytes32(0));

            timelockController.schedule(core, 0, acceptPayload, acceptPredecessor, acceptSalt, delay);
            if (delay == 0) {
                timelockController.execute(core, 0, acceptPayload, acceptPredecessor, acceptSalt);
            }
        }

        vm.stopBroadcast();
    }
}
