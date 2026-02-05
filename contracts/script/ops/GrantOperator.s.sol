// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { OllaCore } from "src/core/OllaCore.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title GrantOperator
/// @notice Local convenience: grant OPERATOR_ROLE to a target address.
contract GrantOperator is BaseScript {
    function run() external {
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        uint256 pk = _privateKey();
        address target = vm.envOr("TARGET", vm.addr(pk));

        vm.startBroadcast(pk);
        OllaCore(core).grantRole(OllaCore(core).OPERATOR_ROLE(), target);
        vm.stopBroadcast();
    }
}
