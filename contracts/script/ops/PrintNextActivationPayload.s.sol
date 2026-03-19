// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintNextActivationPayload
/// @notice Prints exactly one next activation payload for strict-chain governance flows.
/// @dev Output is intended for Safe/multisig submission to OllaGovernance.
contract PrintNextActivationPayload is BaseScript {
    struct OperationState {
        bytes32 id;
        bool pending;
        bool ready;
        bool done;
        uint256 timestamp;
    }

    uint256 internal constant _TOTAL_STEPS = 6;

    function run() external view {
        string memory env = _deployEnv();

        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");
        address vault = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");

        OllaGovernance gov = OllaGovernance(payable(governance));

        bytes32 predecessor = bytes32(0);
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        uint256 delay = gov.getMinDelay();

        bytes memory setVaultData = abi.encodeCall(OllaCore.setVault, (vault));
        bytes memory unpauseCoreData = abi.encodeCall(OllaCore.unpause, ());
        bytes memory unpauseVaultData = abi.encodeCall(OllaVault.unpause, ());

        bytes32 setVaultOpId = gov.hashOperation(core, 0, setVaultData, predecessor, salt);
        OperationState memory setVaultOp = _operationState(gov, setVaultOpId);

        bytes32 unpauseCorePredecessor = _selectUnpauseCorePredecessor(core, vault, setVaultOpId, setVaultOp);
        bytes32 unpauseCoreOpId = gov.hashOperation(core, 0, unpauseCoreData, unpauseCorePredecessor, salt);
        OperationState memory unpauseCoreOp = _operationState(gov, unpauseCoreOpId);

        bytes32 unpauseVaultPredecessor = _selectUnpauseVaultPredecessor(core, unpauseCoreOpId, unpauseCoreOp);
        bytes32 unpauseVaultOpId = gov.hashOperation(vault, 0, unpauseVaultData, unpauseVaultPredecessor, salt);
        OperationState memory unpauseVaultOp = _operationState(gov, unpauseVaultOpId);

        console2.log("env", env);
        console2.log("chainId", block.chainid);
        console2.log("governance", governance);
        console2.log("multisig (governanceAdmin)", gov.governanceAdmin());
        console2.log("timelock.minDelay", delay);
        console2.log("core", core);
        console2.log("vault", vault);
        console2.log("core.vault(current)", OllaCore(core).vault());
        console2.log("core.paused", OllaCore(core).paused());
        console2.log("vault.paused", OllaVault(vault).paused());

        if (OllaCore(core).vault() != vault) {
            _printNextAction(
                gov,
                "setVault",
                "OllaCore.setVault(vault)",
                governance,
                core,
                setVaultData,
                predecessor,
                salt,
                delay,
                setVaultOp,
                1,
                2,
                "After execution, rerun to generate unpauseCore payload."
            );
            return;
        }

        if (OllaCore(core).paused()) {
            _printNextAction(
                gov,
                "unpauseCore",
                "OllaCore.unpause()",
                governance,
                core,
                unpauseCoreData,
                unpauseCorePredecessor,
                salt,
                delay,
                unpauseCoreOp,
                3,
                4,
                "After execution, rerun to generate unpauseVault payload."
            );
            return;
        }

        if (OllaVault(vault).paused()) {
            _printNextAction(
                gov,
                "unpauseVault",
                "OllaVault.unpause()",
                governance,
                vault,
                unpauseVaultData,
                unpauseVaultPredecessor,
                salt,
                delay,
                unpauseVaultOp,
                5,
                6,
                "After execution, rerun to confirm activation complete."
            );
            return;
        }

        console2.log("step", "Step 6/6: Activation complete");
        console2.log("step.index", uint256(6));
        console2.log("step.total", _TOTAL_STEPS);
        console2.log("next.action", "none");
        console2.log("next.status", "activation_complete");
        console2.log("next.step", "No further activation payloads are required.");
    }

    function _printNextAction(
        OllaGovernance gov,
        string memory actionLabel,
        string memory operationLabel,
        address governance,
        address target,
        bytes memory targetCallData,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay,
        OperationState memory op,
        uint256 scheduleStep,
        uint256 executeStep,
        string memory nextStepAfterExecute
    ) internal view {
        gov;

        bool known = op.pending || op.ready || op.done;

        if (!known) {
            bytes memory payload = abi.encodeWithSignature(
                "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                target,
                0,
                targetCallData,
                predecessor,
                salt,
                delay
            );

            console2.log(
                "step",
                string.concat(
                    "Step ", _toString(scheduleStep), "/", _toString(_TOTAL_STEPS), ": Schedule ", operationLabel
                )
            );
            console2.log("step.index", scheduleStep);
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", string.concat("schedule_", actionLabel));
            console2.log("target.contractToCall", governance);
            console2.log("target.value", uint256(0));
            console2.log("target.operationTarget", target);
            console2.log("target.predecessor");
            console2.logBytes32(predecessor);
            console2.log("target.salt");
            console2.logBytes32(salt);
            console2.log("payload");
            console2.logBytes(payload);
            console2.log("next.step", "After this transaction is mined, rerun this script.");
            return;
        }

        if (op.ready) {
            bytes memory payload = abi.encodeWithSignature(
                "execute(address,uint256,bytes,bytes32,bytes32)", target, 0, targetCallData, predecessor, salt
            );

            console2.log(
                "step",
                string.concat(
                    "Step ", _toString(executeStep), "/", _toString(_TOTAL_STEPS), ": Execute ", operationLabel
                )
            );
            console2.log("step.index", executeStep);
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", string.concat("execute_", actionLabel));
            console2.log("target.contractToCall", governance);
            console2.log("target.value", uint256(0));
            console2.log("target.operationTarget", target);
            console2.log("target.predecessor");
            console2.logBytes32(predecessor);
            console2.log("target.salt");
            console2.logBytes32(salt);
            console2.log("operation.id");
            console2.logBytes32(op.id);
            console2.log("payload");
            console2.logBytes(payload);
            console2.log("next.step", nextStepAfterExecute);
            return;
        }

        if (op.done) {
            console2.log(
                "step",
                string.concat(
                    "Step ",
                    _toString(executeStep),
                    "/",
                    _toString(_TOTAL_STEPS),
                    ": Execute ",
                    operationLabel,
                    " (already done)"
                )
            );
            console2.log("step.index", executeStep);
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", string.concat(actionLabel, "_already_done"));
            console2.log("operation.id");
            console2.logBytes32(op.id);
            console2.log("next.step", "Rerun this script to continue with the next activation step.");
            return;
        }

        console2.log(
            "step",
            string.concat(
                "Step ",
                _toString(executeStep),
                "/",
                _toString(_TOTAL_STEPS),
                ": Execute ",
                operationLabel,
                " (timelock wait)"
            )
        );
        console2.log("step.index", executeStep);
        console2.log("step.total", _TOTAL_STEPS);
        console2.log("next.action", string.concat("wait_for_", actionLabel));
        console2.log("target.contractToCall", governance);
        console2.log("operation.id");
        console2.logBytes32(op.id);
        console2.log("upload.possible", false);
        console2.log("timelock.readyAt", op.timestamp);
        if (op.timestamp > block.timestamp) {
            console2.log("timelock.secondsRemaining", op.timestamp - block.timestamp);
        } else {
            console2.log("timelock.secondsRemaining", uint256(0));
        }
        console2.log("next.step", "Rerun this script at or after timelock.readyAt to generate execute payload.");
    }

    function _operationState(OllaGovernance gov, bytes32 operationId) internal view returns (OperationState memory op) {
        op.id = operationId;
        op.pending = gov.isOperationPending(operationId);
        op.ready = gov.isOperationReady(operationId);
        op.done = gov.isOperationDone(operationId);
        op.timestamp = gov.getTimestamp(operationId);
        return op;
    }

    function _selectUnpauseCorePredecessor(
        address core,
        address vault,
        bytes32 setVaultOpId,
        OperationState memory setVaultOp
    ) internal view returns (bytes32) {
        if (OllaCore(core).vault() != vault) {
            return setVaultOpId;
        }

        // If vault is already wired but the canonical setVault op was never done
        // (e.g. different salt path or direct owner call), do not force an unreachable predecessor.
        if (!setVaultOp.done) {
            return bytes32(0);
        }

        return setVaultOpId;
    }

    function _selectUnpauseVaultPredecessor(address core, bytes32 unpauseCoreOpId, OperationState memory unpauseCoreOp)
        internal
        view
        returns (bytes32)
    {
        if (OllaCore(core).paused()) {
            return unpauseCoreOpId;
        }

        // If core is already unpaused but the canonical unpauseCore op was never done
        // (e.g. direct guardian unpause), avoid locking unpauseVault behind an unreachable predecessor.
        if (!unpauseCoreOp.done) {
            return bytes32(0);
        }

        return unpauseCoreOpId;
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
