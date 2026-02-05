// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title SetRewardRate
/// @notice Sets MockAztecRollup.rewardRatePerSecond.
contract SetRewardRate is BaseScript {
    function run() external {
        address rollup = _addrOrDeployment("ROLLUP", "MockAztecRollup", "ROLLUP missing: set ROLLUP or deploy local");
        uint256 rate = vm.envUint("RATE");
        uint256 pk = _privateKey();

        vm.startBroadcast(pk);
        MockAztecRollup(rollup).setRewardRatePerSecond(rate);
        vm.stopBroadcast();
    }
}
