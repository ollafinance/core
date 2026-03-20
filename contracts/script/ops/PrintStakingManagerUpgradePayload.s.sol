// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { VmSafe } from "@forge-std/Vm.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintStakingManagerUpgradePayload
/// @notice Deploys/chooses a staking manager implementation and prints exactly one next timelock payload step.
/// @dev Intended for strict Safe flows where schedule and execute are separate transactions.
contract PrintStakingManagerUpgradePayload is BaseScript {
    struct OperationState {
        bytes32 id;
        bool pending;
        bool ready;
        bool done;
        uint256 timestamp;
    }

    uint256 internal constant _TOTAL_STEPS = 2;
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        string memory env = _deployEnv();

        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
        address stakingManagerProxy =
            _addrOrDeployment("STAKING_MANAGER_PROXY", "StakingManagerProxy", "STAKING_MANAGER_PROXY missing");

        OllaGovernance gov = OllaGovernance(payable(governance));

        bytes32 predecessor = bytes32(vm.envOr("PREDECESSOR", uint256(0)));
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        bool deployNew = vm.envOr("DEPLOY_NEW", false);
        uint256 delay = gov.getMinDelay();

        address currentImplementation = _proxyImplementation(stakingManagerProxy);
        bytes32 currentCodeHash = _codeHash(currentImplementation);

        address candidateImplementation;
        bool deployedNow;
        bool fromDeployment;

        if (deployNew) {
            if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
                console2.log("env", env);
                console2.log("chainId", block.chainid);
                console2.log("next.action", "blocked_deploy_requires_broadcast");
                console2.log("upload.possible", false);
                console2.log(
                    "next.step",
                    "DEPLOY_NEW=true requires --broadcast so the new StakingManager implementation can be deployed."
                );
                return;
            }
            if (!vm.envExists("PRIVATE_KEY")) {
                console2.log("env", env);
                console2.log("chainId", block.chainid);
                console2.log("next.action", "blocked_missing_private_key_for_deploy");
                console2.log("upload.possible", false);
                console2.log(
                    "next.step", "Set PRIVATE_KEY so this script can deploy the new StakingManager implementation."
                );
                return;
            }

            uint256 pk = _privateKey();
            vm.startBroadcast(pk);
            candidateImplementation = address(new StakingManager());
            vm.stopBroadcast();
            deployedNow = true;

            _setDeploymentAddress(env, "StakingManagerImplementation", candidateImplementation);
        } else {
            candidateImplementation = _tryReadDeployment(env, "StakingManagerImplementation");
            fromDeployment = true;
            if (candidateImplementation == address(0) || candidateImplementation.code.length == 0) {
                console2.log("env", env);
                console2.log("chainId", block.chainid);
                console2.log("next.action", "blocked_missing_deployment_implementation");
                console2.log("upload.possible", false);
                console2.log(
                    "next.step",
                    "Set DEPLOY_NEW=true with --broadcast, or populate .addresses.StakingManagerImplementation in deployments file."
                );
                return;
            }
        }

        bytes32 candidateCodeHash = _codeHash(candidateImplementation);
        bool alreadySameAddress = currentImplementation == candidateImplementation;
        bool alreadySameCode = candidateCodeHash != bytes32(0) && candidateCodeHash == currentCodeHash;

        bytes memory operationData =
            abi.encodeCall(OllaGovernance.upgradeSatellite, (stakingManagerProxy, candidateImplementation));
        bytes32 operationId = gov.hashOperation(governance, 0, operationData, predecessor, salt);
        OperationState memory op = _operationState(gov, operationId);

        console2.log("env", env);
        console2.log("chainId", block.chainid);
        console2.log("governance", governance);
        console2.log("multisig (governanceAdmin)", gov.governanceAdmin());
        console2.log("timelock.minDelay", delay);
        console2.log("stakingManager.proxy", stakingManagerProxy);
        console2.log("stakingManager.implementation.current", currentImplementation);
        console2.log("stakingManager.implementation.candidate", candidateImplementation);
        console2.log(
            "implementation.source", deployedNow ? "deployed_now" : (fromDeployment ? "deployment_file" : "unknown")
        );
        console2.log("implementation.deployedNow", deployedNow);
        console2.log("implementation.alreadySameAddress", alreadySameAddress);
        console2.log("implementation.alreadySameCode", alreadySameCode);

        if (alreadySameAddress || alreadySameCode) {
            console2.log("step", "Step 2/2: Upgrade not required");
            console2.log("step.index", uint256(2));
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", "none");
            console2.log(
                "next.status", alreadySameAddress ? "already_up_to_date_address" : "already_up_to_date_bytecode"
            );
            console2.log("next.step", "No upgrade payload required.");
            address implementationToRecord = alreadySameAddress ? candidateImplementation : currentImplementation;
            _setDeploymentAddress(env, "StakingManagerImplementation", implementationToRecord);
            return;
        }

        _printNextAction(governance, operationData, predecessor, salt, delay, op);

        if (op.done) {
            address postImplementation = _proxyImplementation(stakingManagerProxy);
            if (postImplementation == candidateImplementation) {
                _setDeploymentAddress(env, "StakingManagerImplementation", candidateImplementation);
            }
        }
    }

    function _printNextAction(
        address governance,
        bytes memory operationData,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay,
        OperationState memory op
    ) internal view {
        bool known = op.pending || op.ready || op.done;

        if (!known) {
            bytes memory payload = abi.encodeWithSignature(
                "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                governance,
                0,
                operationData,
                predecessor,
                salt,
                delay
            );

            console2.log(
                "step", "Step 1/2: Schedule OllaGovernance.upgradeSatellite(StakingManagerProxy, newImplementation)"
            );
            console2.log("step.index", uint256(1));
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", "schedule_upgradeStakingManager");
            console2.log("target.contractToCall", governance);
            console2.log("target.value", uint256(0));
            console2.log("target.operationTarget", governance);
            console2.log("target.predecessor");
            console2.logBytes32(predecessor);
            console2.log("target.salt");
            console2.logBytes32(salt);
            console2.log("payload");
            console2.logBytes(payload);
            console2.log("next.step", "After this transaction is mined, rerun this script to get the next step.");
            return;
        }

        if (op.ready) {
            bytes memory payload = abi.encodeWithSignature(
                "execute(address,uint256,bytes,bytes32,bytes32)", governance, 0, operationData, predecessor, salt
            );

            console2.log(
                "step", "Step 2/2: Execute OllaGovernance.upgradeSatellite(StakingManagerProxy, newImplementation)"
            );
            console2.log("step.index", uint256(2));
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", "execute_upgradeStakingManager");
            console2.log("target.contractToCall", governance);
            console2.log("target.value", uint256(0));
            console2.log("target.operationTarget", governance);
            console2.log("target.predecessor");
            console2.logBytes32(predecessor);
            console2.log("target.salt");
            console2.logBytes32(salt);
            console2.log("operation.id");
            console2.logBytes32(op.id);
            console2.log("payload");
            console2.logBytes(payload);
            console2.log("next.step", "After execution, rerun to confirm completion and update deployment artifact.");
            return;
        }

        if (op.done) {
            console2.log("step", "Step 2/2: Upgrade already executed");
            console2.log("step.index", uint256(2));
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", "none");
            console2.log("operation.id");
            console2.logBytes32(op.id);
            console2.log("next.status", "upgrade_complete");
            console2.log("next.step", "No further upgrade payloads are required.");
            return;
        }

        console2.log("step", "Step 2/2: Execute upgrade (timelock wait)");
        console2.log("step.index", uint256(2));
        console2.log("step.total", _TOTAL_STEPS);
        console2.log("next.action", "wait_for_upgradeStakingManager");
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

    function _proxyImplementation(address proxy) internal view returns (address impl) {
        bytes32 value = vm.load(proxy, _IMPLEMENTATION_SLOT);
        impl = address(uint160(uint256(value)));
        return impl;
    }

    function _codeHash(address account) internal view returns (bytes32) {
        if (account == address(0) || account.code.length == 0) {
            return bytes32(0);
        }
        return account.codehash;
    }
}
