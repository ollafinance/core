// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { TimelockController } from "@oz/governance/TimelockController.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title DeployTimelock
/// @notice Deploys an OZ TimelockController for governance actions.
contract DeployTimelock is BaseScript {
    function run() external {
        uint256 pk = _privateKey();
        address proposer = vm.envOr("TIMELOCK_PROPOSER", vm.addr(pk));
        address executor = vm.envOr("TIMELOCK_EXECUTOR", proposer);
        address admin = vm.envOr("TIMELOCK_ADMIN", proposer);
        uint256 minDelay = _uintOr("TIMELOCK_MIN_DELAY", 48 hours);

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory executors = new address[](1);
        executors[0] = executor;

        vm.startBroadcast(pk);
        TimelockController timelock = new TimelockController(minDelay, proposers, executors, admin);
        vm.stopBroadcast();

        _logDeployment("TimelockController", address(timelock));

        string memory env = _deployEnv();
        if (_deploymentExists(env)) {
            string memory jsonKey = "timelock";
            vm.serializeAddress(jsonKey, "TimelockController", address(timelock));
            vm.writeJson(jsonKey, _getDeploymentPath(env), ".addresses.TimelockController");
        } else {
            string memory json = _initDeploymentJson(env, block.chainid, vm.addr(pk));
            json = _addAddressToJson(json, "TimelockController", address(timelock), true);
            json = _closeAddressesJson(json);
            _writeDeploymentJson(env, json);
        }
    }
}
