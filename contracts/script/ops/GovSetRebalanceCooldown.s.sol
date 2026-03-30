// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { GovActionBase } from "./GovActionBase.s.sol";

/// @title GovSetRebalanceCooldown
/// @notice Schedules and executes OllaCore.setRebalanceCooldown() via OllaGovernance timelock.
contract GovSetRebalanceCooldown is GovActionBase {
    function run() external {
        address governance = _governanceAddress();
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");

        uint256 newCooldown = vm.envUint("REBALANCE_COOLDOWN");

        console2.log("governance", governance);
        console2.log("core", core);
        console2.log("rebalanceCooldown(before)", OllaCore(core).rebalanceCooldown());
        console2.log("newCooldown", newCooldown);

        bytes memory data = abi.encodeCall(OllaCore.setRebalanceCooldown, (newCooldown));
        _runTimelockAction(governance, core, data);

        console2.log("rebalanceCooldown(after)", OllaCore(core).rebalanceCooldown());
    }
}
