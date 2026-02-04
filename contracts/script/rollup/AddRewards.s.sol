// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script } from "@forge-std/Script.sol";

import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";

/// @title AddRewards
/// @notice Adds pending rewards to a coinbase.
contract AddRewards is Script {
    function run() external {
        address rollup = vm.envAddress("ROLLUP");
        address coinbase = vm.envAddress("COINBASE");
        uint256 amount = vm.envUint("AMOUNT");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        MockAztecRollup(rollup).addRewards(coinbase, amount);
        vm.stopBroadcast();
    }
}
