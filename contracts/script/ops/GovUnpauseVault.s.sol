// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { GovActionBase } from "./GovActionBase.s.sol";

/// @title GovUnpauseVault
/// @notice Schedules and executes OllaVault.unpause() via OllaGovernance timelock.
contract GovUnpauseVault is GovActionBase {
    function run() external {
        address governance = _governanceAddress();
        address vault = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");

        console2.log("governance", governance);
        console2.log("vault", vault);
        console2.log("vault.paused(before)", OllaVault(vault).paused());

        if (!OllaVault(vault).paused()) {
            console2.log("OllaVault already unpaused");
            return;
        }

        bytes memory data = abi.encodeCall(OllaVault.unpause, ());
        _runTimelockAction(governance, vault, data);

        console2.log("vault.paused(after)", OllaVault(vault).paused());
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
        bytes32 setVaultOpId = governance.hashOperation(core, 0, setVaultData, bytes32(0), _salt());

        bytes memory unpauseCoreData = abi.encodeCall(OllaCore.unpause, ());
        return governance.hashOperation(core, 0, unpauseCoreData, setVaultOpId, _salt());
    }
}
