// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { GovActionBase } from "./GovActionBase.s.sol";

/// @title GovSetVault
/// @notice Schedules and executes OllaCore.setVault(...) via OllaGovernance timelock.
contract GovSetVault is GovActionBase {
    function run() external {
        address governance = _governanceAddress();
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");
        address vault = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");

        console2.log("governance", governance);
        console2.log("core", core);
        console2.log("vault", vault);
        console2.log("core.vault(before)", OllaCore(core).vault());

        if (OllaCore(core).vault() == vault) {
            console2.log("setVault already applied");
            return;
        }

        bytes memory data = abi.encodeCall(OllaCore.setVault, (vault));
        _runTimelockAction(governance, core, data);

        console2.log("core.vault(after)", OllaCore(core).vault());
    }
}
