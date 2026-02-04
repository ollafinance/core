// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script } from "@forge-std/Script.sol";

import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";

/// @title SetRewardRate
/// @notice Sets MockAztecRollup.rewardRatePerSecond.
contract SetRewardRate is Script {
    function run() external {
        address rollup = vm.envAddress("ROLLUP");
        uint256 rate = vm.envUint("RATE");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        MockAztecRollup(rollup).setRewardRatePerSecond(rate);
        vm.stopBroadcast();
    }
}
