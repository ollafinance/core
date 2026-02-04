// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script } from "@forge-std/Script.sol";

import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";

/// @title SetActivationThreshold
/// @notice Sets the mock rollup activation threshold.
contract SetActivationThreshold is Script {
    function run() external {
        address rollup = vm.envAddress("ROLLUP");
        uint256 threshold = vm.envUint("THRESHOLD");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        MockAztecRollup(rollup).setActivationThreshold(threshold);
        vm.stopBroadcast();
    }
}
