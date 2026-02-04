// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script } from "@forge-std/Script.sol";

import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";

/// @title TickRewards
/// @notice Calls MockAztecRollup.tick(coinbase).
contract TickRewards is Script {
    function run() external {
        address rollup = vm.envAddress("ROLLUP");
        address coinbase = vm.envAddress("COINBASE");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        MockAztecRollup(rollup).tick(coinbase);
        vm.stopBroadcast();
    }
}
