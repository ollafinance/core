// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintStakingManagerAttesters
/// @notice Prints attester addresses across staking phases available on-chain:
///         - provider queue (queued)
///         - staking manager active set (active)
///         - exiting count (address enumeration not available in current storage design)
/// @dev Default resolution:
///      1) STAKING_MANAGER env var
///      2) deployments/<DEPLOY_ENV>.json (DEPLOY_ENV defaults to "sepolia") key: StakingManagerProxy
contract PrintStakingManagerAttesters is BaseScript {
    uint256 internal constant _MAX_SLOT_SCAN = 1024;
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view {
        address stakingManager = _resolveStakingManagerAddress();
        address stakingManagerImplementation = _readImplementation(stakingManager);

        IStakingManager manager = IStakingManager(stakingManager);
        uint256 activeCount = manager.getActivatedAttesterCount();
        uint256 exitingCount = manager.getPendingUnstakeCount();
        address providerRegistry = address(manager.stakingProviderRegistry());
        uint256 queueLength = IStakingProviderRegistry(providerRegistry).getQueueLength();

        console2.log("stakingManager", stakingManager);
        console2.log("stakingManagerImplementation", stakingManagerImplementation);
        console2.log("stakingProviderRegistry", providerRegistry);
        console2.log("activeCount", activeCount);
        console2.log("exitingCount", exitingCount);
        console2.log("queueLength", queueLength);

        _printQueuedAttesters(providerRegistry, queueLength);
        _printActiveAttesters(stakingManager, activeCount);

        if (exitingCount > 0) {
            console2.log("exitingAttesterAddresses", "not enumerable (count only)");
        }
    }

    function _resolveStakingManagerAddress() internal view returns (address stakingManager) {
        stakingManager = vm.envOr("STAKING_MANAGER", address(0));
        if (stakingManager != address(0)) {
            return stakingManager;
        }

        string memory env = vm.envOr("DEPLOY_ENV", string("sepolia"));
        stakingManager = _tryReadDeployment(env, "StakingManagerProxy");
        require(stakingManager != address(0), "StakingManager missing");
        return stakingManager;
    }

    function _printQueuedAttesters(address registry, uint256 queueLength) internal view {
        if (queueLength == 0) return;

        uint256 queueMappingSlot = _resolveQueueMappingSlot(registry, queueLength);
        (uint128 first, uint128 last) = _readQueueBounds(registry, queueMappingSlot + 1);
        require(last >= first, "Invalid queue bounds");

        console2.log("queuedAttestersStart");
        for (uint256 i = first; i < last; ++i) {
            address attester = _readQueuedAttester(registry, queueMappingSlot, i);
            if (attester != address(0)) {
                console2.log(attester);
            }
        }
        console2.log("queuedAttestersEnd");
    }

    function _printActiveAttesters(address stakingManager, uint256 activeCount) internal view {
        if (activeCount == 0) return;

        uint256 activeSetSlot = _resolveActiveSetSlot(stakingManager, activeCount);
        bytes32 valuesBase = keccak256(abi.encode(activeSetSlot));

        console2.log("activeAttestersStart");
        for (uint256 i = 0; i < activeCount; ++i) {
            bytes32 word = vm.load(stakingManager, bytes32(uint256(valuesBase) + i));
            address attester = address(uint160(uint256(word)));
            if (attester != address(0)) {
                console2.log(attester);
            }
        }
        console2.log("activeAttestersEnd");
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

    function _resolveActiveSetSlot(address stakingManager, uint256 activeCount) internal view returns (uint256) {
        uint256 probes = activeCount < 3 ? activeCount : 3;

        for (uint256 slot = 0; slot <= _MAX_SLOT_SCAN; ++slot) {
            uint256 length = uint256(vm.load(stakingManager, bytes32(slot)));
            if (length != activeCount) continue;

            bytes32 valuesBase = keccak256(abi.encode(slot));
            bool ok = true;

            for (uint256 i = 0; i < probes; ++i) {
                bytes32 valueWord = vm.load(stakingManager, bytes32(uint256(valuesBase) + i));
                address attester = address(uint160(uint256(valueWord)));
                if (attester == address(0)) {
                    ok = false;
                    break;
                }

                // EnumerableSet positions mapping stores index+1 at slot+1.
                bytes32 posSlot = keccak256(abi.encode(bytes32(uint256(uint160(attester))), slot + 1));
                uint256 oneIndexedPos = uint256(vm.load(stakingManager, posSlot));
                if (oneIndexedPos != i + 1) {
                    ok = false;
                    break;
                }
            }

            if (ok) {
                return slot;
            }
        }

        revert("Active set slot not found");
    }

    function _readQueueBounds(address registry, uint256 slot) internal view returns (uint128 first, uint128 last) {
        bytes32 packed = vm.load(registry, bytes32(slot));
        first = uint128(uint256(packed));
        last = uint128(uint256(packed >> 128));
        return (first, last);
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
