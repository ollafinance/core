// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintDeployment
/// @notice Prints key addresses from `deployments/<env>.json`.
contract PrintDeployment is BaseScript {
    function run() external view {
        string memory env = _deployEnv();

        console2.log("Deployment env", env);

        _logAddr(env, "Asset");
        _logAddr(env, "OllaCoreProxy");
        _logAddr(env, "RewardsAccumulatorProxy");
        _logAddr(env, "StAztec");
        _logAddr(env, "WithdrawalQueueProxy");
        _logAddr(env, "SafetyModule");
        _logAddr(env, "StakingManagerProxy");
        _logAddr(env, "StakingProviderRegistryProxy");
        _logAddr(env, "MockAztecRollup");
        _logAddr(env, "MockAztecRollupRegistry");
    }

    function _logAddr(string memory env, string memory key) internal view {
        address addr = _tryReadDeployment(env, key);
        if (addr == address(0)) {
            console2.log(string.concat(key, " <missing>"));
        } else {
            console2.log(key, addr);
        }
    }
}
