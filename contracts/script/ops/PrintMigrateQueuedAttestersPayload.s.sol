// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintMigrateQueuedAttestersPayload
/// @notice Prints payload metadata for StakingManager.migrateQueuedAttesters(...)
/// @dev If multisig is not DEFAULT_ADMIN_ROLE on StakingManager, prints timelock schedule/execute steps.
contract PrintMigrateQueuedAttestersPayload is BaseScript {
    struct OperationState {
        bytes32 id;
        bool pending;
        bool ready;
        bool done;
        uint256 timestamp;
    }

    function run() external view {
        string memory env = _deployEnv();

        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
        address stakingManager =
            _addrOrDeployment("STAKING_MANAGER_PROXY", "StakingManagerProxy", "STAKING_MANAGER_PROXY missing");

        OllaGovernance gov = OllaGovernance(payable(governance));
        address multisig = gov.governanceAdmin();

        address[] memory attesters = vm.envAddress("ATTESTERS", ",");
        uint256[] memory stakedAmounts = vm.envUint("STAKED_AMOUNTS", ",");
        require(attesters.length == stakedAmounts.length, "ATTESTERS/STAKED_AMOUNTS length mismatch");
        require(attesters.length > 0, "ATTESTERS cannot be empty");

        bytes memory migrateData = abi.encodeCall(StakingManager.migrateQueuedAttesters, (attesters, stakedAmounts));

        bytes32 defaultAdminRole = bytes32(0);
        bool multisigIsAdmin = IAccessControl(stakingManager).hasRole(defaultAdminRole, multisig);
        bool governanceIsAdmin = IAccessControl(stakingManager).hasRole(defaultAdminRole, governance);

        console2.log("env", env);
        console2.log("chainId", block.chainid);
        console2.log("governance", governance);
        console2.log("multisig (governanceAdmin)", multisig);
        console2.log("stakingManager", stakingManager);
        console2.log("attesters.count", attesters.length);
        for (uint256 i = 0; i < attesters.length; ++i) {
            console2.log("attester", attesters[i]);
            console2.log("stakedAmount", stakedAmounts[i]);
        }
        console2.log("multisig.isStakingManagerDefaultAdmin", multisigIsAdmin);
        console2.log("governanceProxy.isStakingManagerDefaultAdmin", governanceIsAdmin);

        if (multisigIsAdmin) {
            console2.log("step", "Step 1/1: Direct call migrateQueuedAttesters");
            console2.log("next.action", "execute_migrateQueuedAttesters_direct");
            console2.log("caller", multisig);
            console2.log("target.contractToCall", stakingManager);
            console2.log("target.value", uint256(0));
            console2.log("payload");
            console2.logBytes(migrateData);
            console2.log("next.step", "Submit this transaction from the multisig.");
            return;
        }

        if (!governanceIsAdmin) {
            console2.log("step", "Step 1/1: Blocked");
            console2.log("next.action", "blocked_missing_default_admin");
            console2.log("upload.possible", false);
            console2.log("next.step", "Neither multisig nor governance proxy has DEFAULT_ADMIN_ROLE on StakingManager.");
            return;
        }

        bytes32 predecessor = bytes32(vm.envOr("PREDECESSOR", uint256(0)));
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        uint256 delay = gov.getMinDelay();

        bytes32 operationId = gov.hashOperation(stakingManager, 0, migrateData, predecessor, salt);
        OperationState memory op = _operationState(gov, operationId);
        bool known = op.pending || op.ready || op.done;

        if (!known) {
            bytes memory payload = abi.encodeWithSignature(
                "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                stakingManager,
                0,
                migrateData,
                predecessor,
                salt,
                delay
            );

            console2.log("step", "Step 1/2: Schedule migrateQueuedAttesters");
            console2.log("next.action", "schedule_migrateQueuedAttesters");
            console2.log("caller", multisig);
            console2.log("target.contractToCall", governance);
            console2.log("target.value", uint256(0));
            console2.log("target.operationTarget", stakingManager);
            console2.log("target.predecessor");
            console2.logBytes32(predecessor);
            console2.log("target.salt");
            console2.logBytes32(salt);
            console2.log("payload");
            console2.logBytes(payload);
            console2.log("next.step", "After this transaction is mined, rerun to get the next step.");
            return;
        }

        if (op.ready) {
            bytes memory payload = abi.encodeWithSignature(
                "execute(address,uint256,bytes,bytes32,bytes32)", stakingManager, 0, migrateData, predecessor, salt
            );

            console2.log("step", "Step 2/2: Execute migrateQueuedAttesters");
            console2.log("next.action", "execute_migrateQueuedAttesters");
            console2.log("caller", multisig);
            console2.log("target.contractToCall", governance);
            console2.log("target.value", uint256(0));
            console2.log("target.operationTarget", stakingManager);
            console2.log("operation.id");
            console2.logBytes32(op.id);
            console2.log("payload");
            console2.logBytes(payload);
            console2.log("next.step", "Submit execute tx from multisig.");
            return;
        }

        if (op.done) {
            console2.log("step", "Step 2/2: migrateQueuedAttesters already executed");
            console2.log("next.action", "none");
            console2.log("operation.id");
            console2.logBytes32(op.id);
            console2.log("next.step", "No further payload required for this operation id.");
            return;
        }

        console2.log("step", "Step 2/2: Execute migrateQueuedAttesters (timelock wait)");
        console2.log("next.action", "wait_for_migrateQueuedAttesters");
        console2.log("caller", multisig);
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
        console2.log("next.step", "Rerun this script at or after timelock.readyAt for execute payload.");
    }

    function _operationState(OllaGovernance gov, bytes32 operationId) internal view returns (OperationState memory op) {
        op.id = operationId;
        op.pending = gov.isOperationPending(operationId);
        op.ready = gov.isOperationReady(operationId);
        op.done = gov.isOperationDone(operationId);
        op.timestamp = gov.getTimestamp(operationId);
    }
}
