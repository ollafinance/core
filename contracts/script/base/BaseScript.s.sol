// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { BaseDeployer } from "./BaseDeployer.s.sol";

/// @title BaseScript
/// @notice Shared helpers for operator/provider/rollup scripts.
/// @dev Defaults are safe for local Anvil only (chain id 31337).
abstract contract BaseScript is BaseDeployer {
    /// @notice Default Anvil private key (account 0).
    uint256 internal constant _ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function _deployEnv() internal view returns (string memory) {
        return vm.envOr("DEPLOY_ENV", string("local"));
    }

    function _privateKey() internal view returns (uint256 pk) {
        pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return pk;

        if (block.chainid == 31337) {
            return _ANVIL_PRIVATE_KEY;
        }

        revert("PRIVATE_KEY required on non-local chains");
    }

    function _addrOrDeployment(string memory envVar, string memory deploymentKey, string memory err)
        internal
        view
        returns (address addr)
    {
        addr = vm.envOr(envVar, address(0));
        if (addr == address(0)) {
            addr = _tryReadDeployment(_deployEnv(), deploymentKey);
        }
        require(addr != address(0), err);
    }

    function _uintOr(string memory envVar, uint256 defaultValue) internal view returns (uint256) {
        return vm.envOr(envVar, defaultValue);
    }
}
