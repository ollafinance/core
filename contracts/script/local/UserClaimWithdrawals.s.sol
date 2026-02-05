// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { OllaCore } from "src/core/OllaCore.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title UserClaimWithdrawals
/// @notice Local convenience: claims all finalized withdrawals for the broadcaster.
contract UserClaimWithdrawals is BaseScript {
    function run() external {
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        uint256 pk = _privateKey();
        address user = vm.addr(pk);
        address queueAddr = _addrOrDeployment(
            "WITHDRAWAL_QUEUE", "WithdrawalQueueProxy", "WITHDRAWAL_QUEUE missing: set WITHDRAWAL_QUEUE or deploy local"
        );

        uint256[] memory ids = OllaCore(core).activeRequestIds(user);
        IWithdrawalQueue queue = IWithdrawalQueue(queueAddr);

        vm.startBroadcast(pk);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            IWithdrawalQueue.WithdrawalRequest memory r = queue.getRequest(id);
            if (r.finalized && !r.claimed) {
                OllaCore(core).claimRequestById(id);
            }
        }
        vm.stopBroadcast();
    }
}
