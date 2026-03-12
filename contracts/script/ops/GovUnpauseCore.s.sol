// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { GovActionBase } from "./GovActionBase.s.sol";

/// @title GovUnpauseCore
/// @notice Schedules and executes OllaCore.unpause() via OllaGovernance timelock.
contract GovUnpauseCore is GovActionBase {
    function run() external {
        address governance = _governanceAddress();
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");

        console2.log("governance", governance);
        console2.log("core", core);
        console2.log("core.paused(before)", OllaCore(core).paused());

        if (!OllaCore(core).paused()) {
            console2.log("OllaCore already unpaused");
            return;
        }

        bytes memory data = abi.encodeCall(OllaCore.unpause, ());
        _runTimelockAction(governance, core, data);

        console2.log("core.paused(after)", OllaCore(core).paused());
    }

    function _defaultPredecessor(OllaGovernance governance, address, bytes memory)
        internal
        view
        override
        returns (bytes32)
    {
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");
        address vault = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");
        bytes memory setVaultData = abi.encodeCall(OllaCore.setVault, (vault));
        return governance.hashOperation(core, 0, setVaultData, bytes32(0), _salt());
    }
}
