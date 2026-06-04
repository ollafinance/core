// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { VmSafe } from "@forge-std/Vm.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title GovEmergencyUnpauseAll
/// @notice Calls OllaGovernance.emergencyUnpauseAll() to unpause OllaCore and OllaVault.
/// @dev This is not timelocked. It must be broadcast by the governanceAdmin address.
///      It does NOT unpause the SafetyModule; use PrintSafetyModuleUnpausePayload.s.sol for that.
contract GovEmergencyUnpauseAll is BaseScript {
    function run() external {
        address governance = _governanceAddress();
        OllaGovernance gov = OllaGovernance(payable(governance));
        address governanceAdmin = gov.governanceAdmin();
        address core = gov.core();
        address vault = OllaCore(core).vault();
        // Active SafetyModule (canonical, hot-swappable) - the artifact address may be stale.
        address safetyModule = OllaCore(core).safetyModule();

        bool corePausedBefore = OllaCore(core).paused();
        bool vaultPausedBefore = OllaVault(vault).paused();
        bool safetyModulePaused = SafetyModule(safetyModule).isPaused();
        bool safetyModuleDepositPaused = SafetyModule(safetyModule).isDepositPaused();
        ISafetyModule.BreakerReason breakerReason = SafetyModule(safetyModule).lastBreakerReason();

        console2.log("governance", governance);
        console2.log("governanceAdmin", governanceAdmin);
        console2.log("core", core);
        console2.log("vault", vault);
        console2.log("safetyModule (active)", safetyModule);
        console2.log("core.paused(before)", corePausedBefore);
        console2.log("vault.paused(before)", vaultPausedBefore);
        console2.log("safetyModule.isPaused", safetyModulePaused);
        console2.log("safetyModule.isDepositPaused", safetyModuleDepositPaused);
        console2.log("safetyModule.lastBreakerReason", uint256(breakerReason));

        // Even when OllaCore and OllaVault are unpaused, deposits still revert while the SafetyModule
        // blocks them (e.g. RateDrop/AccountingStale). Do NOT report "already unpaused" in that case.
        if (!corePausedBefore && !vaultPausedBefore) {
            if (safetyModuleDepositPaused) {
                console2.log("status", "OllaCore/OllaVault unpaused but SafetyModule still blocks deposits");
                console2.log("next.action", "unpause_safety_module");
                console2.log(
                    "next.step",
                    "This script does not unpause the SafetyModule. Run PrintSafetyModuleUnpausePayload.s.sol"
                    " and submit the unpause payload via the guardian."
                );
                return;
            }
            console2.log("protocol already unpaused");
            return;
        }

        uint256 pk = _privateKey();
        address caller = vm.addr(pk);
        console2.log("caller", caller);
        require(caller == governanceAdmin, "GovEmergencyUnpauseAll: caller must be governanceAdmin");

        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            revert("GovActionBase: --broadcast required");
        }

        vm.startBroadcast(pk);
        gov.emergencyUnpauseAll();
        vm.stopBroadcast();

        console2.log("core.paused(after)", OllaCore(core).paused());
        console2.log("vault.paused(after)", OllaVault(vault).paused());

        if (SafetyModule(safetyModule).isDepositPaused()) {
            console2.log("warn", "SafetyModule still blocks deposits after unpausing OllaCore/OllaVault");
            console2.log(
                "next.step",
                "Run PrintSafetyModuleUnpausePayload.s.sol and submit the unpause payload via the guardian."
            );
        }
    }

    function _governanceAddress() internal view returns (address) {
        return _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
    }
}
