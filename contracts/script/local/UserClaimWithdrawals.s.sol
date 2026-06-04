// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { BaseScript } from "./../base/BaseScript.s.sol";

/// @title UserClaimWithdrawals
/// @notice Local convenience: claims all finalized withdrawals for the broadcaster.
contract UserClaimWithdrawals is BaseScript {
    function run() external {
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        uint256 pk = _privateKey();
        address user = vm.addr(pk);
        address vaultAddr = IOllaCore(core).vault();

        uint256[] memory ids = IOllaVault(vaultAddr).activeRequestIds(user);

        vm.startBroadcast(pk);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            // activeRequestIds includes pending (unfinalized) requests; claimRequestById reverts
            // OllaVault__NotFinalized for those. Skip them so the batch claims only finalized requests.
            if (!IOllaVault(vaultAddr).getWithdrawalRequest(id).finalized) {
                continue;
            }
            IOllaVault(vaultAddr).claimRequestById(id);
        }
        vm.stopBroadcast();
    }
}
