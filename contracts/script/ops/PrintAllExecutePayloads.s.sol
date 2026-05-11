// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintAllExecutePayloads
/// @notice Prints all 4 activation execute payloads in one go, for batched Safe submission.
/// @dev Run this AFTER the schedule batch from PrintAllSchedulePayloads has had its 3-day timelock elapse.
///      Submit the 4 calls as one Safe MultiSendCallOnly batch in the order shown.
contract PrintAllExecutePayloads is BaseScript {
    uint256 internal constant _DEFAULT_REBALANCE_COOLDOWN = 86400;

    function run() external view {
        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");
        address vault = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");

        OllaGovernance gov = OllaGovernance(payable(governance));

        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        uint256 desiredCooldown = vm.envOr("REBALANCE_COOLDOWN", _DEFAULT_REBALANCE_COOLDOWN);

        // Must match exactly the values used in PrintAllSchedulePayloads.
        bytes memory setVaultData = abi.encodeCall(OllaCore.setVault, (vault));
        bytes memory unpauseCoreData = abi.encodeCall(OllaCore.unpause, ());
        bytes memory setCooldownData = abi.encodeCall(OllaCore.setRebalanceCooldown, (desiredCooldown));
        bytes memory unpauseVaultData = abi.encodeCall(OllaVault.unpause, ());

        bytes32 setVaultOpId = gov.hashOperation(core, 0, setVaultData, bytes32(0), salt);
        bytes32 unpauseCoreOpId = gov.hashOperation(core, 0, unpauseCoreData, setVaultOpId, salt);
        bytes32 setCooldownOpId = gov.hashOperation(core, 0, setCooldownData, unpauseCoreOpId, salt);
        bytes32 unpauseVaultOpId = gov.hashOperation(vault, 0, unpauseVaultData, setCooldownOpId, salt);

        console2.log("============================================================");
        console2.log("BATCHED ACTIVATION EXECUTE PAYLOADS");
        console2.log("============================================================");
        console2.log("chainId", block.chainid);
        console2.log("governance (call target for all 4)", governance);
        console2.log("desiredCooldown (seconds)", desiredCooldown);
        console2.log("salt");
        console2.logBytes32(salt);
        console2.log("");
        console2.log("Readiness check:");
        _logReadiness(gov, "setVault", setVaultOpId);
        _logReadiness(gov, "unpauseCore", unpauseCoreOpId);
        _logReadiness(gov, "setRebalanceCooldown", setCooldownOpId);
        _logReadiness(gov, "unpauseVault", unpauseVaultOpId);
        console2.log("");
        console2.log("Submit all 4 calls below as ONE Safe MultiSendCallOnly batch, in this order.");
        console2.log("Each call targets the OllaGovernance proxy with value=0.");
        console2.log("============================================================");

        _printExecute(1, "setVault", governance, core, setVaultData, bytes32(0), salt, setVaultOpId);
        _printExecute(2, "unpauseCore", governance, core, unpauseCoreData, setVaultOpId, salt, unpauseCoreOpId);
        _printExecute(
            3, "setRebalanceCooldown", governance, core, setCooldownData, unpauseCoreOpId, salt, setCooldownOpId
        );
        _printExecute(4, "unpauseVault", governance, vault, unpauseVaultData, setCooldownOpId, salt, unpauseVaultOpId);
    }

    function _logReadiness(OllaGovernance gov, string memory label, bytes32 opId) internal view {
        bool pending = gov.isOperationPending(opId);
        bool ready = gov.isOperationReady(opId);
        bool done = gov.isOperationDone(opId);
        uint256 readyAt = gov.getTimestamp(opId);

        console2.log("  ", label);
        console2.log("    pending", pending);
        console2.log("    ready", ready);
        console2.log("    done", done);
        console2.log("    readyAt (unix seconds)", readyAt);
        if (readyAt > block.timestamp) {
            console2.log("    secondsRemaining", readyAt - block.timestamp);
        }
    }

    function _printExecute(
        uint256 stepIndex,
        string memory actionLabel,
        address governance,
        address target,
        bytes memory targetCallData,
        bytes32 predecessor,
        bytes32 salt,
        bytes32 opId
    ) internal pure {
        bytes memory payload = abi.encodeWithSignature(
            "execute(address,uint256,bytes,bytes32,bytes32)", target, uint256(0), targetCallData, predecessor, salt
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
        console2.log("operation.id");
        console2.logBytes32(opId);
        console2.log("payload (Safe tx 'data')");
        console2.logBytes(payload);
    }
}
