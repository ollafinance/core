// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintProviderQueueAttesters
/// @notice Prints queued attester ETH addresses from StakingProviderRegistry storage.
/// @dev Default registry resolution order:
///      1) STAKING_PROVIDER_REGISTRY env var
///      2) deployments/<DEPLOY_ENV>.json (DEPLOY_ENV defaults to "sepolia") key: StakingProviderRegistryProxy
///
///      Optional override for another implementation/proxy:
///      STAKING_PROVIDER_REGISTRY=<REGISTRY_ADDRESS> forge script script/ops/PrintProviderQueueAttesters.s.sol:PrintProviderQueueAttesters --rpc-url sepolia
contract PrintProviderQueueAttesters is BaseScript {
    uint256 internal constant _MAX_SLOT_SCAN = 512;
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view {
        address registry = _resolveRegistryAddress();
        _printAttesters(registry);
    }

    function _resolveRegistryAddress() internal view returns (address registry) {
        registry = vm.envOr("STAKING_PROVIDER_REGISTRY", address(0));
        if (registry != address(0)) {
            return registry;
        }

        string memory env = vm.envOr("DEPLOY_ENV", string("sepolia"));
        registry = _tryReadDeployment(env, "StakingProviderRegistryProxy");
        require(registry != address(0), "StakingProviderRegistry missing");
        return registry;
    }

    function _printAttesters(address registry) internal view {
        address implementation = _readImplementation(registry);
        uint256 queueLength = IStakingProviderRegistry(registry).getQueueLength();
        console2.log("stakingProviderRegistry", registry);
        console2.log("stakingProviderRegistryImplementation", implementation);
        console2.log("queueLength", queueLength);

        if (implementation != address(0) && implementation.code.length > 0) {
            try IStakingProviderRegistry(implementation).getQueueLength() returns (uint256 implementationQueueLength) {
                console2.log("implementationQueueLength", implementationQueueLength);
            } catch {
                console2.log("implementationQueueLength call failed");
            }
        }

        if (queueLength == 0) return;

        uint256 queueMappingSlot = _resolveQueueMappingSlot(registry, queueLength);

        (uint128 first, uint128 last) = _readQueueBounds(registry, queueMappingSlot + 1);
        require(last >= first, "Invalid queue bounds");

        for (uint256 i = first; i < last; ++i) {
            address attester = _readQueuedAttester(registry, queueMappingSlot, i);
            if (attester != address(0)) {
                // Print only the attester ETH address.
                console2.log(attester);
            }
        }
    }

    function _resolveQueueMappingSlot(address registry, uint256 queueLength) internal view returns (uint256) {
        for (uint256 slot = 1; slot <= _MAX_SLOT_SCAN; ++slot) {
            (uint128 first, uint128 last) = _readQueueBounds(registry, slot);
            if (last < first) continue;
            if (uint256(last - first) != queueLength) continue;
            if (first == 0) continue;

            uint256 queueMappingSlot = slot - 1;
            address firstAttester = _readQueuedAttester(registry, queueMappingSlot, uint256(first));
            if (firstAttester != address(0)) {
                return queueMappingSlot;
            }
        }

        revert("Queue slot not found");
    }

    function _readQueueBounds(address registry, uint256 slot) internal view returns (uint128 first, uint128 last) {
        bytes32 packed = vm.load(registry, bytes32(slot));
        first = uint128(uint256(packed));
        last = uint128(uint256(packed >> 128));
    }

    function _readQueuedAttester(address registry, uint256 queueMappingSlot, uint256 queueIndex)
        internal
        view
        returns (address)
    {
        bytes32 base = keccak256(abi.encode(queueIndex, queueMappingSlot));
        bytes32 word = vm.load(registry, base);
        return address(uint160(uint256(word)));
    }

    function _readImplementation(address proxy) internal view returns (address) {
        bytes32 word = vm.load(proxy, _IMPLEMENTATION_SLOT);
        return address(uint160(uint256(word)));
    }
}
