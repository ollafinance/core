// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title TickRewards
/// @notice Calls MockAztecRollup.tick(coinbase).
contract TickRewards is BaseScript {
    function run() external {
        address rollup = _addrOrDeployment("ROLLUP", "MockAztecRollup", "ROLLUP missing: set ROLLUP or deploy local");
        address coinbase =
            _addrOrDeployment("COINBASE", "RewardsAccumulatorProxy", "COINBASE missing: set COINBASE or deploy local");
        uint256 pk = _privateKey();

        vm.startBroadcast(pk);
        MockAztecRollup(rollup).tick(coinbase);
        vm.stopBroadcast();
    }
}
