// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title SetActivationThreshold
/// @notice Sets the mock rollup activation threshold.
contract SetActivationThreshold is BaseScript {
    function run() external {
        address rollup = _addrOrDeployment("ROLLUP", "MockAztecRollup", "ROLLUP missing: set ROLLUP or deploy local");
        uint256 threshold = vm.envUint("THRESHOLD");
        uint256 pk = _privateKey();

        vm.startBroadcast(pk);
        MockAztecRollup(rollup).setActivationThreshold(threshold);
        vm.stopBroadcast();
    }
}
