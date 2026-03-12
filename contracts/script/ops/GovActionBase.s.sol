// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title GovActionBase
/// @notice Base helper for idempotent timelock schedule/execute ops scripts.
abstract contract GovActionBase is BaseScript {
    function _runTimelockAction(address governance, address target, bytes memory data) internal {
        OllaGovernance gov = OllaGovernance(payable(governance));
        bytes32 predecessor = _predecessor(gov, target, data);
        bytes32 salt = _salt();
        bytes32 operationId = gov.hashOperation(target, 0, data, predecessor, salt);

        _logOperation("before", gov, operationId);

        if (gov.isOperationDone(operationId)) {
            console2.log("operation already executed");
            _logOperation("after", gov, operationId);
            return;
        }

        uint256 delay = gov.getMinDelay();
        uint256 pk = _privateKey();

        vm.startBroadcast(pk);

        if (!_isKnownOperation(gov, operationId)) {
            if (delay == 0 && block.chainid == 31337 && block.timestamp == 1) {
                vm.warp(block.timestamp + 1);
            }
            gov.schedule(target, 0, data, predecessor, salt, delay);
            console2.log("scheduled operation");
        }

        if (gov.isOperationReady(operationId)) {
            gov.execute(target, 0, data, predecessor, salt);
            console2.log("executed operation");
        } else {
            console2.log("operation not ready yet");
            console2.log("readyAt", gov.getTimestamp(operationId));
        }

        vm.stopBroadcast();

        _logOperation("after", gov, operationId);
    }

    function _governanceAddress() internal view returns (address) {
        return _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");
    }

    function _predecessor(OllaGovernance governance, address target, bytes memory data)
        internal
        view
        returns (bytes32)
    {
        if (vm.envExists("PREDECESSOR")) {
            return bytes32(vm.envUint("PREDECESSOR"));
        }
        return _defaultPredecessor(governance, target, data);
    }

    function _defaultPredecessor(OllaGovernance governance, address target, bytes memory data)
        internal
        view
        virtual
        returns (bytes32)
    {
        governance;
        target;
        data;
        return bytes32(0);
    }

    function _salt() internal view returns (bytes32) {
        return bytes32(vm.envOr("SALT", uint256(0)));
    }

    function _isKnownOperation(OllaGovernance gov, bytes32 operationId) internal view returns (bool) {
        return
            gov.isOperationPending(operationId) || gov.isOperationReady(operationId) || gov.isOperationDone(operationId);
    }

    function _logOperation(string memory label, OllaGovernance gov, bytes32 operationId) internal view {
        console2.log(label);
        console2.logBytes32(operationId);
        console2.log("pending", gov.isOperationPending(operationId));
        console2.log("ready", gov.isOperationReady(operationId));
        console2.log("done", gov.isOperationDone(operationId));
        console2.log("timestamp", gov.getTimestamp(operationId));
    }
}
