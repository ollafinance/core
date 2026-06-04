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

    uint256 internal constant _TOTAL_STEPS = 10;
    uint256 internal constant _DEFAULT_REBALANCE_COOLDOWN = 86400;

    function run() external view {
        string memory env = _deployEnv();

        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");
        address vault = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");

        OllaGovernance gov = OllaGovernance(payable(governance));

        bytes32 predecessor = bytes32(0);
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        uint256 delay = gov.getMinDelay();
        uint256 desiredCooldown = vm.envOr("REBALANCE_COOLDOWN", _DEFAULT_REBALANCE_COOLDOWN);

        // OllaGovernance.setCore(core) is scheduled at deploy time (target = governance proxy,
        // predecessor = 0, salt = 0). On strict chains with a nonzero delay it stays pending until
        // executed here; until then OllaGovernance.core() is unset and the emergency wrappers and
        // every governance passthrough that dereferences core are unusable. setCore is one-time
        // (it reverts once core is set), so this step is gated on gov.core() == address(0).
        bytes memory setCoreData = abi.encodeCall(OllaGovernance.setCore, (core));
        bytes32 setCoreOpId = gov.hashOperation(governance, 0, setCoreData, bytes32(0), bytes32(0));
        OperationState memory setCoreOp = _operationState(gov, setCoreOpId);

        bytes memory setVaultData = abi.encodeCall(OllaCore.setVault, (vault));
        bytes memory unpauseCoreData = abi.encodeCall(OllaCore.unpause, ());
        bytes memory setCooldownData = abi.encodeCall(OllaCore.setRebalanceCooldown, (desiredCooldown));
        bytes memory unpauseVaultData = abi.encodeCall(OllaVault.unpause, ());

        bytes32 setVaultOpId = gov.hashOperation(core, 0, setVaultData, predecessor, salt);
        OperationState memory setVaultOp = _operationState(gov, setVaultOpId);

        bytes32 unpauseCorePredecessor = _selectUnpauseCorePredecessor(core, vault, setVaultOpId, setVaultOp);
        bytes32 unpauseCoreOpId = gov.hashOperation(core, 0, unpauseCoreData, unpauseCorePredecessor, salt);
        OperationState memory unpauseCoreOp = _operationState(gov, unpauseCoreOpId);

        bytes32 setCooldownPredecessor = _selectSetCooldownPredecessor(core, unpauseCoreOpId, unpauseCoreOp);
        bytes32 setCooldownOpId = gov.hashOperation(core, 0, setCooldownData, setCooldownPredecessor, salt);
        OperationState memory setCooldownOp = _operationState(gov, setCooldownOpId);

        bytes32 unpauseVaultPredecessor =
            _selectUnpauseVaultPredecessor(core, desiredCooldown, setCooldownOpId, setCooldownOp);
        bytes32 unpauseVaultOpId = gov.hashOperation(vault, 0, unpauseVaultData, unpauseVaultPredecessor, salt);
        OperationState memory unpauseVaultOp = _operationState(gov, unpauseVaultOpId);

        console2.log("env", env);
        console2.log("chainId", block.chainid);
        console2.log("governance", governance);
        console2.log("multisig (governanceAdmin)", gov.governanceAdmin());
        console2.log("timelock.minDelay", delay);
        console2.log("core", core);
        console2.log("vault", vault);
        console2.log("gov.core(current)", gov.core());
        console2.log("gov.core(desired)", core);
        console2.log("core.vault(current)", OllaCore(core).vault());
        console2.log("core.paused", OllaCore(core).paused());
        console2.log("vault.paused", OllaVault(vault).paused());
        console2.log("core.rebalanceCooldown(current)", OllaCore(core).rebalanceCooldown());
        console2.log("core.rebalanceCooldown(desired)", desiredCooldown);

        if (gov.core() == address(0)) {
            _printNextAction(
                gov,
                "setGovernanceCore",
                "OllaGovernance.setCore(core)",
                governance,
                governance,
                setCoreData,
                bytes32(0),
                bytes32(0),
                delay,
                setCoreOp,
                1,
                2,
                "After execution, rerun to generate setVault payload."
            );
            return;
        }

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
                3,
                4,
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
                5,
                6,
                "After execution, rerun to generate setRebalanceCooldown payload."
            );
            return;
        }

        if (OllaCore(core).rebalanceCooldown() != desiredCooldown) {
            _printNextAction(
                gov,
                "setRebalanceCooldown",
                "OllaCore.setRebalanceCooldown(desired)",
                governance,
                core,
                setCooldownData,
                setCooldownPredecessor,
                salt,
                delay,
                setCooldownOp,
                7,
                8,
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
                9,
                10,
                "After execution, rerun to confirm activation complete."
            );
            return;
        }

        console2.log("step", "Step 10/10: Activation complete");
        console2.log("step.index", uint256(10));
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

    function _selectSetCooldownPredecessor(address core, bytes32 unpauseCoreOpId, OperationState memory unpauseCoreOp)
        internal
        view
        returns (bytes32)
    {
        if (OllaCore(core).paused()) {
            return unpauseCoreOpId;
        }

        // If core is already unpaused but the canonical unpauseCore op was never done
        // (e.g. direct guardian unpause), avoid locking setRebalanceCooldown behind an unreachable predecessor.
        if (!unpauseCoreOp.done) {
            return bytes32(0);
        }

        return unpauseCoreOpId;
    }

    function _selectUnpauseVaultPredecessor(
        address core,
        uint256 desiredCooldown,
        bytes32 setCooldownOpId,
        OperationState memory setCooldownOp
    ) internal view returns (bytes32) {
        if (OllaCore(core).rebalanceCooldown() != desiredCooldown) {
            return setCooldownOpId;
        }

        // If cooldown is already at desired but the canonical setRebalanceCooldown op was never done
        // (e.g. direct owner call), avoid locking unpauseVault behind an unreachable predecessor.
        if (!setCooldownOp.done) {
            return bytes32(0);
        }

        return setCooldownOpId;
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
            // casting to 'uint8' is safe because value % 10 is always in range [0,9], so 48 + result is in [48,57]
            // forge-lint: disable-next-line(unsafe-typecast)
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
