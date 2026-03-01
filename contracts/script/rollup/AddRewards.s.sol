// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title AddRewards
/// @notice Adds pending rewards to a coinbase.
contract AddRewards is BaseScript {
    function run() external {
        address rollup = _addrOrDeployment("ROLLUP", "MockAztecRollup", "ROLLUP missing: set ROLLUP or deploy local");
        address coinbase =
            _addrOrDeployment("COINBASE", "RewardsCollectorProxy", "COINBASE missing: set COINBASE or deploy local");
        uint256 amount = vm.envUint("AMOUNT");
        uint256 pk = _privateKey();

        vm.startBroadcast(pk);
        MockAztecRollup(rollup).addRewards(coinbase, amount);
        vm.stopBroadcast();
    }
}
