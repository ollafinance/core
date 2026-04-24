// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintNextProtocolUpgradePayload
/// @notice Prints exactly one next timelock payload step for protocol-wide upgrades.
/// @dev Intended for strict multisig flows where schedule and execute are separate transactions.
contract PrintNextProtocolUpgradePayload is BaseScript {
    struct OperationState {
        bytes32 id;
        bool pending;
        bool ready;
        bool done;
        uint256 timestamp;
    }

    uint256 internal constant _TOTAL_STEPS = 14;
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view {
        string memory env = _deployEnv();

        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
        address queueProxy =
            _addrOrDeployment("WITHDRAWAL_QUEUE_PROXY", "WithdrawalQueueProxy", "WITHDRAWAL_QUEUE_PROXY missing");
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

        address queueImpl = _implCandidate("WITHDRAWAL_QUEUE_IMPLEMENTATION", env, "WithdrawalQueueImplementation");
        address rewardsImpl =
            _implCandidate("REWARDS_ACCUMULATOR_IMPLEMENTATION", env, "RewardsAccumulatorImplementation");
        address sprImpl =
            _implCandidate("STAKING_PROVIDER_REGISTRY_IMPLEMENTATION", env, "StakingProviderRegistryImplementation");
        address stakingManagerImpl =
            _implCandidate("STAKING_MANAGER_IMPLEMENTATION", env, "StakingManagerImplementation");
        address vaultImpl = _implCandidate("VAULT_IMPLEMENTATION", env, "OllaVaultImplementation");
        address coreImpl = _implCandidate("CORE_IMPLEMENTATION", env, "OllaCoreImplementation");
        address governanceImpl = _implCandidate("GOVERNANCE_IMPLEMENTATION", env, "OllaGovernanceImplementation");

        OllaGovernance gov = OllaGovernance(payable(governance));

        bytes32 rootPredecessor = bytes32(vm.envOr("PREDECESSOR", uint256(0)));
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        uint256 delay = gov.getMinDelay();

        address queueCurrent = _proxyImplementation(queueProxy);
        address rewardsCurrent = _proxyImplementation(rewardsProxy);
        address sprCurrent = _proxyImplementation(sprProxy);
        address stakingManagerCurrent = _proxyImplementation(stakingManagerProxy);
        address vaultCurrent = _proxyImplementation(vaultProxy);
        address coreCurrent = _proxyImplementation(coreProxy);
        address governanceCurrent = _proxyImplementation(governance);

        bool queueUpToDate = _isUpToDate(queueCurrent, queueImpl);
        bool rewardsUpToDate = _isUpToDate(rewardsCurrent, rewardsImpl);
        bool sprUpToDate = _isUpToDate(sprCurrent, sprImpl);
        bool stakingManagerUpToDate = _isUpToDate(stakingManagerCurrent, stakingManagerImpl);
        bool vaultUpToDate = _isUpToDate(vaultCurrent, vaultImpl);
        bool coreUpToDate = _isUpToDate(coreCurrent, coreImpl);
        bool governanceUpToDate = _isUpToDate(governanceCurrent, governanceImpl);

        bool hasAnyTargetChange = !(queueUpToDate && rewardsUpToDate && sprUpToDate && stakingManagerUpToDate
                && vaultUpToDate && coreUpToDate && governanceUpToDate);

        console2.log("env", env);
        console2.log("chainId", block.chainid);
        console2.log("governance", governance);
        console2.log("multisig (governanceAdmin)", gov.governanceAdmin());
        console2.log("timelock.minDelay", delay);
        console2.log("root.predecessor");
        console2.logBytes32(rootPredecessor);
        console2.log("salt");
        console2.logBytes32(salt);

        _logComponent("withdrawalQueue", queueProxy, queueCurrent, queueImpl, queueUpToDate);
        _logComponent("rewardsAccumulator", rewardsProxy, rewardsCurrent, rewardsImpl, rewardsUpToDate);
        _logComponent("stakingProviderRegistry", sprProxy, sprCurrent, sprImpl, sprUpToDate);
        _logComponent(
            "stakingManager", stakingManagerProxy, stakingManagerCurrent, stakingManagerImpl, stakingManagerUpToDate
        );
        _logComponent("vault", vaultProxy, vaultCurrent, vaultImpl, vaultUpToDate);
        _logComponent("core", coreProxy, coreCurrent, coreImpl, coreUpToDate);
        _logComponent("governance", governance, governanceCurrent, governanceImpl, governanceUpToDate);

        if (!hasAnyTargetChange) {
            // Distinguish "all upgraded" from "no targets configured" by checking whether
            // any timelock operation in the canonical chain was executed (done).
            bytes memory queueData = abi.encodeCall(OllaGovernance.upgradeSatellite, (queueProxy, queueImpl, bytes("")));
            bytes32 queueOpId = gov.hashOperation(governance, 0, queueData, rootPredecessor, salt);
            bool anyOpDone = gov.isOperationDone(queueOpId);

            if (anyOpDone) {
                console2.log("step", "Step 14/14: Upgrade campaign complete");
                console2.log("step.index", uint256(14));
                console2.log("step.total", _TOTAL_STEPS);
                console2.log("next.action", "none");
                console2.log("next.status", "upgrade_complete");
                console2.log("next.step", "No further upgrade payloads are required.");
            } else {
                console2.log("step", "Step 0/14: No pending upgrade targets configured");
                console2.log("step.index", uint256(0));
                console2.log("step.total", _TOTAL_STEPS);
                console2.log("next.action", "blocked_missing_upgrade_targets");
                console2.log("upload.possible", false);
                console2.log(
                    "next.step",
                    string.concat(
                        "Deploy new implementations and set *_IMPLEMENTATION env overrides, or update ",
                        "deployments/<env>.json, so candidates differ from current proxy implementations."
                    )
                );
            }
            return;
        }

        bytes memory queueData = abi.encodeCall(OllaGovernance.upgradeSatellite, (queueProxy, queueImpl, bytes("")));
        bytes32 queueCanonicalOpId = gov.hashOperation(governance, 0, queueData, rootPredecessor, salt);
        OperationState memory queueCanonicalOp = _operationState(gov, queueCanonicalOpId);

        if (!queueUpToDate) {
            _printNextAction(
                gov,
                "upgradeWithdrawalQueue",
                "OllaGovernance.upgradeSatellite(WithdrawalQueueProxy,newImplementation)",
                governance,
                governance,
                queueData,
                rootPredecessor,
                salt,
                delay,
                queueCanonicalOp,
                1,
                2,
                "After execution, rerun to generate the RewardsAccumulator upgrade payload."
            );
            return;
        }

        bytes memory rewardsData =
            abi.encodeCall(OllaGovernance.upgradeSatellite, (rewardsProxy, rewardsImpl, bytes("")));
        bytes32 rewardsCanonicalPredecessor = queueCanonicalOpId;
        bytes32 rewardsCanonicalOpId = gov.hashOperation(governance, 0, rewardsData, rewardsCanonicalPredecessor, salt);
        OperationState memory rewardsCanonicalOp = _operationState(gov, rewardsCanonicalOpId);
        bytes32 rewardsSelectedPredecessor =
            _selectPredecessor(queueUpToDate, queueCanonicalOpId, queueCanonicalOp, rewardsCanonicalPredecessor);
        OperationState memory rewardsOp = rewardsCanonicalOp;
        if (rewardsSelectedPredecessor != rewardsCanonicalPredecessor) {
            rewardsOp =
                _operationState(gov, gov.hashOperation(governance, 0, rewardsData, rewardsSelectedPredecessor, salt));
        }

        if (!rewardsUpToDate) {
            _printNextAction(
                gov,
                "upgradeRewardsAccumulator",
                "OllaGovernance.upgradeSatellite(RewardsAccumulatorProxy,newImplementation)",
                governance,
                governance,
                rewardsData,
                rewardsSelectedPredecessor,
                salt,
                delay,
                rewardsOp,
                3,
                4,
                "After execution, rerun to generate the StakingProviderRegistry upgrade payload."
            );
            return;
        }

        bytes memory sprData = abi.encodeCall(OllaGovernance.upgradeSatellite, (sprProxy, sprImpl, bytes("")));
        bytes32 sprCanonicalPredecessor = rewardsCanonicalOpId;
        bytes32 sprCanonicalOpId = gov.hashOperation(governance, 0, sprData, sprCanonicalPredecessor, salt);
        OperationState memory sprCanonicalOp = _operationState(gov, sprCanonicalOpId);
        bytes32 sprSelectedPredecessor =
            _selectPredecessor(rewardsUpToDate, rewardsCanonicalOpId, rewardsCanonicalOp, sprCanonicalPredecessor);
        OperationState memory sprOp = sprCanonicalOp;
        if (sprSelectedPredecessor != sprCanonicalPredecessor) {
            sprOp = _operationState(gov, gov.hashOperation(governance, 0, sprData, sprSelectedPredecessor, salt));
        }

        if (!sprUpToDate) {
            _printNextAction(
                gov,
                "upgradeStakingProviderRegistry",
                "OllaGovernance.upgradeSatellite(StakingProviderRegistryProxy,newImplementation)",
                governance,
                governance,
                sprData,
                sprSelectedPredecessor,
                salt,
                delay,
                sprOp,
                5,
                6,
                "After execution, rerun to generate the StakingManager upgrade payload."
            );
            return;
        }

        bytes memory stakingManagerData =
            abi.encodeCall(OllaGovernance.upgradeSatellite, (stakingManagerProxy, stakingManagerImpl, bytes("")));
        bytes32 stakingManagerCanonicalPredecessor = sprCanonicalOpId;
        bytes32 stakingManagerCanonicalOpId =
            gov.hashOperation(governance, 0, stakingManagerData, stakingManagerCanonicalPredecessor, salt);
        OperationState memory stakingManagerCanonicalOp = _operationState(gov, stakingManagerCanonicalOpId);
        bytes32 stakingManagerSelectedPredecessor =
            _selectPredecessor(sprUpToDate, sprCanonicalOpId, sprCanonicalOp, stakingManagerCanonicalPredecessor);
        OperationState memory stakingManagerOp = stakingManagerCanonicalOp;
        if (stakingManagerSelectedPredecessor != stakingManagerCanonicalPredecessor) {
            stakingManagerOp = _operationState(
                gov, gov.hashOperation(governance, 0, stakingManagerData, stakingManagerSelectedPredecessor, salt)
            );
        }

        if (!stakingManagerUpToDate) {
            _printNextAction(
                gov,
                "upgradeStakingManager",
                "OllaGovernance.upgradeSatellite(StakingManagerProxy,newImplementation)",
                governance,
                governance,
                stakingManagerData,
                stakingManagerSelectedPredecessor,
                salt,
                delay,
                stakingManagerOp,
                7,
                8,
                "After execution, rerun to generate the OllaVault upgrade payload."
            );
            return;
        }

        bytes memory vaultData = abi.encodeCall(OllaGovernance.upgradeSatellite, (vaultProxy, vaultImpl, bytes("")));
        bytes32 vaultCanonicalPredecessor = stakingManagerCanonicalOpId;
        bytes32 vaultCanonicalOpId = gov.hashOperation(governance, 0, vaultData, vaultCanonicalPredecessor, salt);
        OperationState memory vaultCanonicalOp = _operationState(gov, vaultCanonicalOpId);
        bytes32 vaultSelectedPredecessor = _selectPredecessor(
            stakingManagerUpToDate, stakingManagerCanonicalOpId, stakingManagerCanonicalOp, vaultCanonicalPredecessor
        );
        OperationState memory vaultOp = vaultCanonicalOp;
        if (vaultSelectedPredecessor != vaultCanonicalPredecessor) {
            vaultOp = _operationState(gov, gov.hashOperation(governance, 0, vaultData, vaultSelectedPredecessor, salt));
        }

        if (!vaultUpToDate) {
            _printNextAction(
                gov,
                "upgradeVault",
                "OllaGovernance.upgradeSatellite(OllaVaultProxy,newImplementation)",
                governance,
                governance,
                vaultData,
                vaultSelectedPredecessor,
                salt,
                delay,
                vaultOp,
                9,
                10,
                "After execution, rerun to generate the OllaCore upgrade payload."
            );
            return;
        }

        bytes memory coreData = abi.encodeCall(OllaGovernance.upgradeCore, (coreImpl, bytes("")));
        bytes32 coreCanonicalPredecessor = vaultCanonicalOpId;
        bytes32 coreCanonicalOpId = gov.hashOperation(governance, 0, coreData, coreCanonicalPredecessor, salt);
        OperationState memory coreCanonicalOp = _operationState(gov, coreCanonicalOpId);
        bytes32 coreSelectedPredecessor =
            _selectPredecessor(vaultUpToDate, vaultCanonicalOpId, vaultCanonicalOp, coreCanonicalPredecessor);
        OperationState memory coreOp = coreCanonicalOp;
        if (coreSelectedPredecessor != coreCanonicalPredecessor) {
            coreOp = _operationState(gov, gov.hashOperation(governance, 0, coreData, coreSelectedPredecessor, salt));
        }

        if (!coreUpToDate) {
            _printNextAction(
                gov,
                "upgradeCore",
                "OllaGovernance.upgradeCore(newImplementation)",
                governance,
                governance,
                coreData,
                coreSelectedPredecessor,
                salt,
                delay,
                coreOp,
                11,
                12,
                "After execution, rerun to generate the OllaGovernance upgrade payload."
            );
            return;
        }

        bytes memory governanceUpgradeData =
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", governanceImpl, bytes(""));
        bytes32 governanceCanonicalPredecessor = coreCanonicalOpId;
        bytes32 governanceCanonicalOpId =
            gov.hashOperation(governance, 0, governanceUpgradeData, governanceCanonicalPredecessor, salt);
        OperationState memory governanceCanonicalOp = _operationState(gov, governanceCanonicalOpId);
        bytes32 governanceSelectedPredecessor =
            _selectPredecessor(coreUpToDate, coreCanonicalOpId, coreCanonicalOp, governanceCanonicalPredecessor);
        OperationState memory governanceOp = governanceCanonicalOp;
        if (governanceSelectedPredecessor != governanceCanonicalPredecessor) {
            governanceOp = _operationState(
                gov, gov.hashOperation(governance, 0, governanceUpgradeData, governanceSelectedPredecessor, salt)
            );
        }

        if (!governanceUpToDate) {
            _printNextAction(
                gov,
                "upgradeGovernance",
                "OllaGovernanceProxy.upgradeToAndCall(newImplementation, \"\")",
                governance,
                governance,
                governanceUpgradeData,
                governanceSelectedPredecessor,
                salt,
                delay,
                governanceOp,
                13,
                14,
                "After execution, rerun to confirm upgrade campaign complete."
            );
            return;
        }

        console2.log("step", "Step 14/14: Upgrade campaign complete");
        console2.log("step.index", uint256(14));
        console2.log("step.total", _TOTAL_STEPS);
        console2.log("next.action", "none");
        console2.log("next.status", "upgrade_complete");
        console2.log("next.step", "No further upgrade payloads are required.");
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
        if (currentImplementation == candidateImplementation) {
            return true;
        }

        bytes32 currentCodeHash = _codeHash(currentImplementation);
        bytes32 candidateCodeHash = _codeHash(candidateImplementation);
        return candidateCodeHash != bytes32(0) && candidateCodeHash == currentCodeHash;
    }

    function _selectPredecessor(
        bool previousStepSatisfiedByState,
        bytes32 previousCanonicalOpId,
        OperationState memory previousCanonicalOp,
        bytes32 canonicalPredecessor
    ) internal view returns (bytes32) {
        previousCanonicalOpId;
        if (!previousStepSatisfiedByState) {
            return canonicalPredecessor;
        }

        if (!previousCanonicalOp.done) {
            return bytes32(0);
        }

        return canonicalPredecessor;
    }

    function _logComponent(
        string memory label,
        address proxy,
        address currentImpl,
        address candidateImpl,
        bool upToDate
    ) internal view {
        console2.log(string.concat(label, ".proxy"), proxy);
        console2.log(string.concat(label, ".implementation.current"), currentImpl);
        console2.log(string.concat(label, ".implementation.candidate"), candidateImpl);
        console2.log(string.concat(label, ".upToDate"), upToDate);
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
            console2.log("next.step", "Rerun this script to continue with the next upgrade step.");
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
