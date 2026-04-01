// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title SendEthTo
/// @notice Sends native ETH to a target address.
/// @dev Supports sending a percentage of a base amount (or full sender balance).
contract SendEthTo is BaseScript {
    function run() external {
        uint256 pk = _privateKey();
        address to = vm.envAddress("TO");
        require(to != address(0), "TO must be nonzero");

        // Percentage to send from the base amount. Defaults to 100.
        // Example split flow:
        // 1) PERCENT=50 to address A (sends half of base)
        // 2) PERCENT=100 to address B (sends all remaining base)
        uint256 percent = vm.envOr("PERCENT", uint256(100));
        require(percent > 0 && percent <= 100, "PERCENT must be 1..100");

        // Optional explicit base amount for precision. If omitted, use sender spendable balance
        // (wallet balance minus a gas reserve) so PERCENT=100 can still succeed.
        uint256 baseAmountWei = vm.envOr("AMOUNT_WEI", uint256(0));
        if (baseAmountWei == 0) {
            uint256 amountGwei = vm.envOr("AMOUNT_GWEI", uint256(0));
            baseAmountWei = amountGwei * 1 gwei;
        }

        if (baseAmountWei == 0) {
            uint256 balanceWei = vm.addr(pk).balance;

            // Gas reserve strategy:
            // 1) If GAS_RESERVE_WEI is set, use it directly.
            // 2) Else reserve GAS_RESERVE_UNITS * tx.gasprice (default 50k gas units).
            uint256 gasReserveWei = vm.envOr("GAS_RESERVE_WEI", uint256(0));
            if (gasReserveWei == 0) {
                uint256 gasReserveUnits = vm.envOr("GAS_RESERVE_UNITS", uint256(50_000));
                gasReserveWei = gasReserveUnits * tx.gasprice;
            }

            require(balanceWei > gasReserveWei, "insufficient balance after gas reserve");
            baseAmountWei = balanceWei - gasReserveWei;
        }

        uint256 amountWei = (baseAmountWei * percent) / 100;
        require(amountWei > 0, "computed amount is zero");
        require(vm.addr(pk).balance >= amountWei, "insufficient sender balance");

        vm.startBroadcast(pk);
        (bool ok,) = payable(to).call{ value: amountWei }("");
        require(ok, "ETH transfer failed");
        vm.stopBroadcast();
    }
}
