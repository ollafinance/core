// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintAllSchedulePayloads
/// @notice Prints all 4 activation schedule payloads in one go, for batched Safe submission.
/// @dev Output is intended for a single Safe MultiSendCallOnly batch containing all 4 schedule calls,
///      so the 3-day timelock runs in parallel for every operation.
contract PrintAllSchedulePayloads is BaseScript {
    uint256 internal constant _DEFAULT_REBALANCE_COOLDOWN = 86400;

    function run() external view {
        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");
        address vault = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");

        OllaGovernance gov = OllaGovernance(payable(governance));

        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        uint256 delay = gov.getMinDelay();
        uint256 desiredCooldown = vm.envOr("REBALANCE_COOLDOWN", _DEFAULT_REBALANCE_COOLDOWN);

        // Encode the target call data for each activation step.
        bytes memory setVaultData = abi.encodeCall(OllaCore.setVault, (vault));
        bytes memory unpauseCoreData = abi.encodeCall(OllaCore.unpause, ());
        bytes memory setCooldownData = abi.encodeCall(OllaCore.setRebalanceCooldown, (desiredCooldown));
        bytes memory unpauseVaultData = abi.encodeCall(OllaVault.unpause, ());

        // Compute predecessor chain so execution order is enforced post-timelock.
        bytes32 setVaultOpId = gov.hashOperation(core, 0, setVaultData, bytes32(0), salt);
        bytes32 unpauseCoreOpId = gov.hashOperation(core, 0, unpauseCoreData, setVaultOpId, salt);
        bytes32 setCooldownOpId = gov.hashOperation(core, 0, setCooldownData, unpauseCoreOpId, salt);
        bytes32 unpauseVaultOpId = gov.hashOperation(vault, 0, unpauseVaultData, setCooldownOpId, salt);

        console2.log("============================================================");
        console2.log("BATCHED ACTIVATION SCHEDULE PAYLOADS");
        console2.log("============================================================");
        console2.log("chainId", block.chainid);
        console2.log("governance (call target for all 4)", governance);
        console2.log("multisig (governanceAdmin)", gov.governanceAdmin());
        console2.log("timelock.minDelay (seconds)", delay);
        console2.log("desiredCooldown (seconds)", desiredCooldown);
        console2.log("salt");
        console2.logBytes32(salt);
        console2.log("");
        console2.log("Submit all 4 calls below as ONE Safe MultiSendCallOnly batch.");
        console2.log("Each call targets the OllaGovernance proxy with value=0.");
        console2.log("After 3 days, submit the corresponding 4 execute() calls as a second batch.");
        console2.log("============================================================");

        _printSchedule(1, "setVault", governance, core, setVaultData, bytes32(0), salt, delay, setVaultOpId);
        _printSchedule(2, "unpauseCore", governance, core, unpauseCoreData, setVaultOpId, salt, delay, unpauseCoreOpId);
        _printSchedule(
            3, "setRebalanceCooldown", governance, core, setCooldownData, unpauseCoreOpId, salt, delay, setCooldownOpId
        );
        _printSchedule(
            4, "unpauseVault", governance, vault, unpauseVaultData, setCooldownOpId, salt, delay, unpauseVaultOpId
        );

        console2.log("============================================================");
        console2.log("FOR THE EXECUTE PHASE (after 3 days), use PrintAllExecutePayloads");
        console2.log("with the SAME SALT and REBALANCE_COOLDOWN values.");
        console2.log("============================================================");
    }

    function _printSchedule(
        uint256 stepIndex,
        string memory actionLabel,
        address governance,
        address target,
        bytes memory targetCallData,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay,
        bytes32 opId
    ) internal pure {
        bytes memory payload = abi.encodeWithSignature(
            "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
            target,
            uint256(0),
            targetCallData,
            predecessor,
            salt,
            delay
        );

        console2.log("");
        console2.log("------------------------------------------------------------");
        console2.log("Step", stepIndex);
        console2.log("action", actionLabel);
        console2.log("target.contractToCall (Safe tx 'to')", governance);
        console2.log("target.value", uint256(0));
        console2.log("target.operationTarget", target);
        console2.log("predecessor");
        console2.logBytes32(predecessor);
        console2.log("salt");
        console2.logBytes32(salt);
        console2.log("delay", delay);
        console2.log("operation.id");
        console2.logBytes32(opId);
        console2.log("payload (Safe tx 'data')");
        console2.logBytes(payload);
    }
}
