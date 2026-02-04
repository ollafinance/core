// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script } from "@forge-std/Script.sol";

import { OllaCore } from "src/core/OllaCore.sol";

/// @title Rebalance
/// @notice Calls OllaCore.rebalance() as operator.
contract Rebalance is Script {
    function run() external {
        address core = vm.envAddress("CORE");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        OllaCore(core).rebalance();
        vm.stopBroadcast();
    }
}
