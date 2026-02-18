// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title UserDeposit
/// @notice Local convenience: approves + deposits AZTEC into OllaCore as the broadcaster.
contract UserDeposit is BaseScript {
    function run() external {
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        address asset = _addrOrDeployment("ASSET", "Asset", "ASSET missing: set ASSET or deploy local");
        uint256 pk = _privateKey();

        // AMOUNT is whole tokens (18 decimals).
        uint256 amountTokens = vm.envUint("AMOUNT");
        uint256 amount = amountTokens * 1e18;
        if (amount == 0) {
            return;
        }

        address recipient = vm.envOr("RECIPIENT", vm.addr(pk));

        vm.startBroadcast(pk);
        IERC20(asset).approve(core, amount);
        OllaCore(core).deposit(amount, recipient, 0);
        vm.stopBroadcast();
    }
}
