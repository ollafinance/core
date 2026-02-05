// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { IMockAztecRollup } from "src/staking/mocks/IMockAztecRollup.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title DemoFinalizeWithdraw
/// @notice Demonstrates stake deposit -> initiateWithdraw -> finalizeWithdraw on MockAztecRollup.
contract DemoFinalizeWithdraw is BaseScript {
    function run() external {
        string memory env = _deployEnv();

        address rollup = vm.envOr("ROLLUP", address(0));
        if (rollup == address(0)) {
            rollup = _tryReadDeployment(env, "MockAztecRollup");
        }
        require(rollup != address(0), "ROLLUP missing: set ROLLUP or deploy local");

        uint256 pk = _privateKey();
        address broadcaster = vm.addr(pk);

        address attester = vm.envOr("ATTESTER", broadcaster);
        address recipient = vm.envOr("RECIPIENT", broadcaster);

        uint256 threshold = vm.envOr("THRESHOLD", uint256(10e18));

        IMockAztecRollup r = IMockAztecRollup(rollup);
        IERC20 asset = r.STAKING_ASSET();

        console2.log("env", env);
        console2.log("rollup", rollup);
        console2.log("asset", address(asset));
        console2.log("broadcaster", broadcaster);
        console2.log("attester", attester);
        console2.log("recipient", recipient);

        vm.startBroadcast(pk);

        r.setActivationThreshold(threshold);
        console2.log("activationThreshold", r.getActivationThreshold());

        address coinbase = r.rewardsCoinbase();
        if (coinbase != address(0)) {
            console2.log("rewardsCoinbase", coinbase);
            console2.log("pendingRewards(coinbase) before", r.getSequencerRewards(coinbase));
        }

        console2.log("asset.balance(broadcaster) before", asset.balanceOf(broadcaster));
        console2.log("asset.balance(recipient) before", asset.balanceOf(recipient));
        console2.log("asset.balance(rollup) before", asset.balanceOf(rollup));

        asset.approve(rollup, threshold);

        // Zero keys are fine for the mock.
        G1Point memory g1 = G1Point({ x: 0, y: 0 });
        G2Point memory g2 = G2Point({ x0: 0, x1: 0, y0: 0, y1: 0 });
        G1Point memory pop = G1Point({ x: 0, y: 0 });

        r.deposit(attester, broadcaster, g1, g2, pop, false);
        console2.log("stake after deposit", r.stakes(attester));

        r.initiateWithdraw(attester, recipient);
        console2.log("exit exists after initiate", r.getExit(attester).exists);

        if (coinbase != address(0)) {
            console2.log("pendingRewards(coinbase) after initiate", r.getSequencerRewards(coinbase));
        }

        r.finalizeWithdraw(attester);
        console2.log("stake after finalize", r.stakes(attester));

        console2.log("asset.balance(broadcaster) after", asset.balanceOf(broadcaster));
        console2.log("asset.balance(recipient) after", asset.balanceOf(recipient));
        console2.log("asset.balance(rollup) after", asset.balanceOf(rollup));

        vm.stopBroadcast();
    }
}
