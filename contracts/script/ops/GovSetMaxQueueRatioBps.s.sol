// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { GovActionBase } from "./GovActionBase.s.sol";

/// @title GovSetMaxQueueRatioBps
/// @notice Schedules and executes SafetyModule.setMaxQueueRatioBps() via OllaGovernance timelock.
/// @dev Targets the governance passthrough so the ACTIVE SafetyModule (OllaCore.safetyModule()) is
///      resolved at execution time, surviving SafetyModule hot-swaps and stale deployment artifacts.
contract GovSetMaxQueueRatioBps is GovActionBase {
    function run() external {
        address governance = _governanceAddress();
        OllaGovernance gov = OllaGovernance(payable(governance));
        address core = gov.core();
        address safetyModule = OllaCore(core).safetyModule();

        uint256 newBps = vm.envUint("MAX_QUEUE_RATIO_BPS");

        console2.log("governance", governance);
        console2.log("core", core);
        console2.log("safetyModule (active)", safetyModule);
        console2.log("maxQueueRatioBps(before)", SafetyModule(safetyModule).maxQueueRatioBps());
        console2.log("newBps", newBps);

        // Schedule against the governance passthrough rather than the SafetyModule directly so the
        // active module is resolved at execution time via ISafetyModule(IOllaCore(core).safetyModule()).
        bytes memory data = abi.encodeCall(OllaGovernance.setMaxQueueRatioBps, (newBps));
        _runTimelockAction(governance, governance, data);

        console2.log("maxQueueRatioBps(after)", SafetyModule(OllaCore(core).safetyModule()).maxQueueRatioBps());
    }
}
