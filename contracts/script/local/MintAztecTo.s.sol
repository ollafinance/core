// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20Mintable } from "src/interfaces/IERC20Mintable.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title MintAztecTo
/// @notice Local convenience: mints mock AZTEC to a target address.
contract MintAztecTo is BaseScript {
    function run() external {
        address asset = _addrOrDeployment("ASSET", "Asset", "ASSET missing: set ASSET or deploy local");
        uint256 pk = _privateKey();

        // Default is Anvil account-1 address.
        address to = vm.envOr("TO", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));

        // AMOUNT is whole tokens (18 decimals).
        uint256 amountTokens = vm.envUint("AMOUNT");
        uint256 amount = amountTokens * 1e18;
        if (amount == 0) {
            return;
        }

        vm.startBroadcast(pk);
        IERC20Mintable(asset).mint(to, amount);
        vm.stopBroadcast();
    }
}
