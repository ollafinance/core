// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script } from "@forge-std/Script.sol";

import { OllaCore } from "src/core/OllaCore.sol";

/// @title GrantOperator
/// @notice Local convenience: grant OPERATOR_ROLE to a target address.
contract GrantOperator is Script {
    function run() external {
        address core = vm.envAddress("CORE");
        address target = vm.envAddress("TARGET");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        OllaCore(core).grantRole(OllaCore(core).OPERATOR_ROLE(), target);
        vm.stopBroadcast();
    }
}
