// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title AddKeys
/// @notice Adds N dummy keystores to the staking provider registry.
/// @dev Keys are not used by the mock rollup, but must be present for StakingManager.stake().
///      Attester addresses are deterministic — running twice with the same COUNT will revert
///      because the registry rejects duplicate attester addresses.
contract AddKeys is BaseScript {
    function run() external {
        address stakingProviderRegistry = _addrOrDeployment(
            "STAKING_PROVIDER_REGISTRY",
            "StakingProviderRegistryProxy",
            "STAKING_PROVIDER_REGISTRY missing: set STAKING_PROVIDER_REGISTRY or deploy local"
        );
        uint256 count = _uintOr("COUNT", 5);
        uint256 pk = _privateKey();

        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            // Deterministic dummy addresses/points; only attester is used by the staking manager.
            address attester = address(uint160(uint256(keccak256(abi.encodePacked("olla-attester", i)))));
            keys[i] = IStakingManager.KeyStore({
                attester: attester,
                publicKeyG1: G1Point({ x: 1, y: 2 }),
                publicKeyG2: G2Point({ x0: 1, x1: 2, y0: 3, y1: 4 }),
                proofOfPossession: G1Point({ x: 5, y: 6 })
            });
        }

        vm.startBroadcast(pk);
        StakingProviderRegistry(stakingProviderRegistry).addKeysToProvider(keys);
        vm.stopBroadcast();
    }
}
