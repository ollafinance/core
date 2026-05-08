// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title GovEmergencyUnpauseAll
/// @notice Calls OllaGovernance.emergencyUnpauseAll() to unpause OllaCore and OllaVault.
/// @dev This is not timelocked. It must be broadcast by the governanceAdmin address.
contract GovEmergencyUnpauseAll is BaseScript {
    function run() external {
        address governance = _governanceAddress();
        OllaGovernance gov = OllaGovernance(payable(governance));
        address governanceAdmin = gov.governanceAdmin();
        address core = gov.core();
        address vault = OllaCore(core).vault();

        bool corePausedBefore = OllaCore(core).paused();
        bool vaultPausedBefore = OllaVault(vault).paused();

        console2.log("governance", governance);
        console2.log("governanceAdmin", governanceAdmin);
        console2.log("core", core);
        console2.log("vault", vault);
        console2.log("core.paused(before)", corePausedBefore);
        console2.log("vault.paused(before)", vaultPausedBefore);

        if (!corePausedBefore && !vaultPausedBefore) {
            console2.log("protocol already unpaused");
            return;
        }

        uint256 pk = _privateKey();
        address caller = vm.addr(pk);
        console2.log("caller", caller);
        require(caller == governanceAdmin, "GovEmergencyUnpauseAll: caller must be governanceAdmin");

        vm.startBroadcast(pk);
        gov.emergencyUnpauseAll();
        vm.stopBroadcast();

        console2.log("core.paused(after)", OllaCore(core).paused());
        console2.log("vault.paused(after)", OllaVault(vault).paused());
    }

    function _governanceAddress() internal view returns (address) {
        return _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
    }
}
