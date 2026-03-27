// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { GovActionBase } from "./GovActionBase.s.sol";

/// @title GovSetMaxQueueRatioBps
/// @notice Schedules and executes SafetyModule.setMaxQueueRatioBps() via OllaGovernance timelock.
contract GovSetMaxQueueRatioBps is GovActionBase {
    function run() external {
        address governance = _governanceAddress();
        address safetyModule = _addrOrDeployment("SAFETY_MODULE", "SafetyModule", "SAFETY_MODULE missing");

        uint256 newBps = vm.envUint("MAX_QUEUE_RATIO_BPS");

        console2.log("governance", governance);
        console2.log("safetyModule", safetyModule);
        console2.log("maxQueueRatioBps(before)", SafetyModule(safetyModule).maxQueueRatioBps());
        console2.log("newBps", newBps);

        bytes memory data = abi.encodeCall(SafetyModule.setMaxQueueRatioBps, (newBps));
        _runTimelockAction(governance, safetyModule, data);

        console2.log("maxQueueRatioBps(after)", SafetyModule(safetyModule).maxQueueRatioBps());
    }
}
