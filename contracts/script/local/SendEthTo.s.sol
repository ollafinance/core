// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title SendEthTo
/// @notice Sends native ETH to a target address.
contract SendEthTo is BaseScript {
    function run() external {
        uint256 pk = _privateKey();
        address to = vm.envAddress("TO");
        require(to != address(0), "TO must be nonzero");

        // Prefer explicit wei amount for precision.
        uint256 amountWei = vm.envOr("AMOUNT_WEI", uint256(0));
        if (amountWei == 0) {
            uint256 amountGwei = vm.envOr("AMOUNT_GWEI", uint256(0));
            amountWei = amountGwei * 1 gwei;
        }
        require(amountWei > 0, "amount missing: set AMOUNT_WEI or AMOUNT_GWEI");

        vm.startBroadcast(pk);
        (bool ok,) = payable(to).call{ value: amountWei }("");
        require(ok, "ETH transfer failed");
        vm.stopBroadcast();
    }
}
