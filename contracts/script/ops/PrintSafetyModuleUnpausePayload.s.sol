// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintSafetyModuleUnpausePayload
/// @notice Prints one calldata payload to unpause SafetyModule when possible.
/// @dev Intended for Safe UI submission. SafetyModule unpause is not timelocked.
contract PrintSafetyModuleUnpausePayload is BaseScript {
    function run() external view {
        string memory env = _deployEnv();
        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
        address safetyModule = _addrOrDeployment("SAFETY_MODULE", "SafetyModule", "SAFETY_MODULE missing");

        OllaGovernance gov = OllaGovernance(payable(governance));
        address multisig = gov.governanceAdmin();
        bytes32 guardianRole = SafetyModule(safetyModule).GUARDIAN_ROLE();

        bool paused = SafetyModule(safetyModule).isPaused();
        bool multisigIsGuardian = IAccessControl(safetyModule).hasRole(guardianRole, multisig);
        bool governanceIsGuardian = IAccessControl(safetyModule).hasRole(guardianRole, governance);

        console2.log("env", env);
        console2.log("chainId", block.chainid);
        console2.log("governance", governance);
        console2.log("multisig (governanceAdmin)", multisig);
        console2.log("safetyModule", safetyModule);
        console2.log("safetyModule.paused", paused);
        console2.log("guardianRole");
        console2.logBytes32(guardianRole);
        console2.log("multisig.isGuardian", multisigIsGuardian);
        console2.log("governanceProxy.isGuardian", governanceIsGuardian);

        if (!paused) {
            console2.log("step", "Step 1/1: SafetyModule already unpaused");
            console2.log("next.action", "none");
            console2.log("next.step", "No action required.");
            return;
        }

        if (!multisigIsGuardian) {
            console2.log("step", "Step 1/1: Cannot unpause with governance multisig");
            console2.log("next.action", "blocked_missing_guardian_role");
            console2.log("upload.possible", false);
            console2.log(
                "next.step", "Use an address with GUARDIAN_ROLE on SafetyModule, or grant multisig that role first."
            );
            return;
        }

        bytes memory payload = abi.encodeCall(SafetyModule.unpause, ());

        console2.log("step", "Step 1/1: Unpause SafetyModule");
        console2.log("next.action", "execute_unpauseSafetyModule");
        console2.log("target.contractToCall", safetyModule);
        console2.log("target.value", uint256(0));
        console2.log("payload");
        console2.logBytes(payload);
        console2.log("next.step", "After this transaction is mined, rerun to verify SafetyModule is unpaused.");
    }
}
