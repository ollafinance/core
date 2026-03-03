// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title UserInitiateWithdrawAll
/// @notice Local convenience: requests redeem of the broadcaster's full stAztec balance.
contract UserInitiateWithdrawAll is BaseScript {
    function run() external {
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        address stAztec = _addrOrDeployment("STAZTEC", "StAztec", "STAZTEC missing: set STAZTEC or deploy local");
        uint256 pk = _privateKey();
        address user = vm.addr(pk);
        address vaultAddr = IOllaCore(core).vault();

        address recipient = vm.envOr("RECIPIENT", user);

        uint256 shares = IERC20(stAztec).balanceOf(user);
        if (shares == 0) {
            return;
        }

        vm.startBroadcast(pk);
        IOllaVault(vaultAddr).requestRedeem(shares, recipient, user);
        vm.stopBroadcast();
    }
}
