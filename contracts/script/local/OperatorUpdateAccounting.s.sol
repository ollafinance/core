// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { OllaCore } from "src/core/OllaCore.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title OperatorUpdateAccounting
/// @notice Local convenience: calls OllaCore.updateAccounting() as operator.
contract OperatorUpdateAccounting is BaseScript {
    function run() external {
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        uint256 pk = _privateKey();

        vm.startBroadcast(pk);
        OllaCore(core).updateAccounting();
        vm.stopBroadcast();
    }
}
