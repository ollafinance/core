// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintNextProtocolUpgradePayload
/// @notice Prints the next timelock payload for protocol-wide upgrades using the fewest transactions possible.
/// @dev Batches all currently-needed implementation upgrades into one scheduleBatch and one executeBatch.
contract PrintNextProtocolUpgradePayload is BaseScript {
    struct OperationState {
        bytes32 id;
        bool pending;
        bool ready;
        bool done;
        uint256 timestamp;
    }

    struct UpgradeTarget {
        string label;
        address proxy;
        address operationTarget;
        address currentImplementation;
        address candidateImplementation;
        bool upToDate;
        bytes callData;
    }

    uint256 internal constant _MAX_UPGRADES = 6;
    uint256 internal constant _TOTAL_STEPS = 2;
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view {
        string memory env = _deployEnv();

        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
        OllaGovernance gov = OllaGovernance(payable(governance));

        UpgradeTarget[] memory targets = _upgradeTargets(env, governance);
        uint256 upgradeCount = _upgradeCount(targets);

        bytes32 predecessor = bytes32(vm.envOr("PREDECESSOR", uint256(0)));
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        uint256 delay = gov.getMinDelay();

        console2.log("env", env);
        console2.log("chainId", block.chainid);
        console2.log("governance", governance);
        console2.log("multisig (governanceAdmin)", gov.governanceAdmin());
        console2.log("timelock.minDelay", delay);
        console2.log("root.predecessor");
        console2.logBytes32(predecessor);
        console2.log("salt");
        console2.logBytes32(salt);

        for (uint256 i; i < targets.length; i++) {
            _logComponent(targets[i]);
        }

        if (upgradeCount == 0) {
            console2.log("step", "Step 2/2: Upgrade campaign complete");
            console2.log("step.index", uint256(2));
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", "none");
            console2.log("next.status", "upgrade_complete_or_no_changes");
            console2.log("next.step", "No upgrade payloads are required.");
            return;
        }

        (address[] memory batchTargets, uint256[] memory values, bytes[] memory payloads, string memory labels) =
            _batch(governance, targets, upgradeCount);

        bytes32 operationId = gov.hashOperationBatch(batchTargets, values, payloads, predecessor, salt);
        OperationState memory op = _operationState(gov, operationId);

        console2.log("batch.upgradeCount", upgradeCount);
        console2.log("batch.labels", labels);

        _printBatchAction(governance, batchTargets, values, payloads, predecessor, salt, delay, op);
    }

    function _upgradeTargets(string memory env, address governance)
        internal
        view
        returns (UpgradeTarget[] memory targets)
    {
        targets = new UpgradeTarget[](_MAX_UPGRADES);

        address rewardsProxy = _addrOrDeployment(
            "REWARDS_ACCUMULATOR_PROXY", "RewardsAccumulatorProxy", "REWARDS_ACCUMULATOR_PROXY missing"
        );
        address sprProxy = _addrOrDeployment(
            "STAKING_PROVIDER_REGISTRY_PROXY", "StakingProviderRegistryProxy", "STAKING_PROVIDER_REGISTRY_PROXY missing"
        );
        address stakingManagerProxy =
            _addrOrDeployment("STAKING_MANAGER_PROXY", "StakingManagerProxy", "STAKING_MANAGER_PROXY missing");
        address vaultProxy = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");
        address coreProxy = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");

        address rewardsImpl =
            _implCandidate("REWARDS_ACCUMULATOR_IMPLEMENTATION", env, "RewardsAccumulatorImplementation");
        address sprImpl =
            _implCandidate("STAKING_PROVIDER_REGISTRY_IMPLEMENTATION", env, "StakingProviderRegistryImplementation");
        address stakingManagerImpl =
            _implCandidate("STAKING_MANAGER_IMPLEMENTATION", env, "StakingManagerImplementation");
        address vaultImpl = _implCandidate("VAULT_IMPLEMENTATION", env, "OllaVaultImplementation");
        address coreImpl = _implCandidate("CORE_IMPLEMENTATION", env, "OllaCoreImplementation");
        address governanceImpl = _implCandidate("GOVERNANCE_IMPLEMENTATION", env, "OllaGovernanceImplementation");

        targets[0] = _satelliteTarget("rewardsAccumulator", rewardsProxy, rewardsImpl);
        targets[1] = _satelliteTarget("stakingProviderRegistry", sprProxy, sprImpl);
        targets[2] = _satelliteTarget("stakingManager", stakingManagerProxy, stakingManagerImpl);
        targets[3] = _satelliteTarget("vault", vaultProxy, vaultImpl);

        address coreCurrent = _proxyImplementation(coreProxy);
        targets[4] = UpgradeTarget({
            label: "core",
            proxy: coreProxy,
            operationTarget: coreProxy,
            currentImplementation: coreCurrent,
            candidateImplementation: coreImpl,
            upToDate: _isUpToDate(coreCurrent, coreImpl),
            callData: abi.encodeWithSignature("upgradeToAndCall(address,bytes)", coreImpl, bytes(""))
        });

        address governanceCurrent = _proxyImplementation(governance);
        targets[5] = UpgradeTarget({
            label: "governance",
            proxy: governance,
            operationTarget: governance,
            currentImplementation: governanceCurrent,
            candidateImplementation: governanceImpl,
            upToDate: _isUpToDate(governanceCurrent, governanceImpl),
            callData: abi.encodeWithSignature("upgradeToAndCall(address,bytes)", governanceImpl, bytes(""))
        });
        return targets;
    }

    function _satelliteTarget(string memory label, address proxy, address candidateImplementation)
        internal
        view
        returns (UpgradeTarget memory target)
    {
        address currentImplementation = _proxyImplementation(proxy);
        target = UpgradeTarget({
            label: label,
            proxy: proxy,
            operationTarget: address(0),
            currentImplementation: currentImplementation,
            candidateImplementation: candidateImplementation,
            upToDate: _isUpToDate(currentImplementation, candidateImplementation),
            callData: abi.encodeCall(OllaGovernance.upgradeSatellite, (proxy, candidateImplementation, bytes("")))
        });
        return target;
    }

    function _implCandidate(string memory envVar, string memory env, string memory deploymentKey)
        internal
        view
        returns (address impl)
    {
        impl = vm.envOr(envVar, address(0));
        if (impl == address(0)) {
            impl = _tryReadDeployment(env, deploymentKey);
        }
        require(impl != address(0), string.concat("Missing implementation address for ", deploymentKey));
        require(impl.code.length > 0, string.concat("No code at implementation for ", deploymentKey));
        return impl;
    }

    function _isUpToDate(address currentImplementation, address candidateImplementation) internal view returns (bool) {
        if (currentImplementation == candidateImplementation) return true;

        bytes32 currentCodeHash = _codeHash(currentImplementation);
        bytes32 candidateCodeHash = _codeHash(candidateImplementation);
        return candidateCodeHash != bytes32(0) && candidateCodeHash == currentCodeHash;
    }

    function _printBatchAction(
        address governance,
        address[] memory batchTargets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay,
        OperationState memory op
    ) internal view {
        bool known = op.pending || op.ready || op.done;

        if (!known) {
            bytes memory payload = abi.encodeWithSignature(
                "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
                batchTargets,
                values,
                payloads,
                predecessor,
                salt,
                delay
            );

            console2.log("step", "Step 1/2: Schedule batched protocol upgrades");
            console2.log("step.index", uint256(1));
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", "scheduleBatch_protocolUpgrades");
            console2.log("target.contractToCall", governance);
            console2.log("target.value", uint256(0));
            console2.log("target.predecessor");
            console2.logBytes32(predecessor);
            console2.log("target.salt");
            console2.logBytes32(salt);
            console2.log("payload");
            console2.logBytes(payload);
            console2.log("next.step", "After this transaction is mined, rerun this script to get the execute payload.");
            return;
        }

        if (op.ready) {
            bytes memory payload = abi.encodeWithSignature(
                "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)",
                batchTargets,
                values,
                payloads,
                predecessor,
                salt
            );

            console2.log("step", "Step 2/2: Execute batched protocol upgrades");
            console2.log("step.index", uint256(2));
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", "executeBatch_protocolUpgrades");
            console2.log("target.contractToCall", governance);
            console2.log("target.value", uint256(0));
            console2.log("target.predecessor");
            console2.logBytes32(predecessor);
            console2.log("target.salt");
            console2.logBytes32(salt);
            console2.log("operation.id");
            console2.logBytes32(op.id);
            console2.log("payload");
            console2.logBytes(payload);
            console2.log("next.step", "After execution, rerun this script to confirm the upgrade campaign is complete.");
            return;
        }

        if (op.done) {
            console2.log("step", "Step 2/2: Batched protocol upgrades already executed");
            console2.log("step.index", uint256(2));
            console2.log("step.total", _TOTAL_STEPS);
            console2.log("next.action", "none");
            console2.log("operation.id");
            console2.logBytes32(op.id);
            console2.log("next.status", "upgrade_complete");
            console2.log("next.step", "No further upgrade payloads are required.");
            return;
        }

        console2.log("step", "Step 2/2: Execute batched protocol upgrades (timelock wait)");
        console2.log("step.index", uint256(2));
        console2.log("step.total", _TOTAL_STEPS);
        console2.log("next.action", "wait_for_executeBatch_protocolUpgrades");
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
        if (account == address(0) || account.code.length == 0) return bytes32(0);
        return account.codehash;
    }

    function _upgradeCount(UpgradeTarget[] memory targets) internal pure returns (uint256 count) {
        for (uint256 i; i < targets.length; i++) {
            if (!targets[i].upToDate) count++;
        }
        return count;
    }

    function _logComponent(UpgradeTarget memory target) internal pure {
        console2.log(string.concat(target.label, ".proxy"), target.proxy);
        console2.log(string.concat(target.label, ".implementation.current"), target.currentImplementation);
        console2.log(string.concat(target.label, ".implementation.candidate"), target.candidateImplementation);
        console2.log(string.concat(target.label, ".upToDate"), target.upToDate);
    }

    function _batch(address governance, UpgradeTarget[] memory targets, uint256 upgradeCount)
        internal
        pure
        returns (address[] memory batchTargets, uint256[] memory values, bytes[] memory payloads, string memory labels)
    {
        batchTargets = new address[](upgradeCount);
        values = new uint256[](upgradeCount);
        payloads = new bytes[](upgradeCount);

        uint256 cursor;
        for (uint256 i; i < targets.length; i++) {
            if (targets[i].upToDate) continue;

            batchTargets[cursor] = targets[i].operationTarget == address(0) ? governance : targets[i].operationTarget;
            values[cursor] = 0;
            payloads[cursor] = targets[i].callData;
            labels = bytes(labels).length == 0 ? targets[i].label : string.concat(labels, ",", targets[i].label);
            cursor++;
        }
        return (batchTargets, values, payloads, labels);
    }
}
