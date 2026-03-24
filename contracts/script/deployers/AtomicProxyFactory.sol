// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Create2 } from "@oz/utils/Create2.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { OllaVault } from "src/vault/OllaVault.sol";

/// @title AtomicProxyFactory
/// @notice Deploys ERC1967 proxies and initializes them in the same transaction.
contract AtomicProxyFactory {
    error AtomicProxyFactory__ZeroAddress(string arg);

    function deployCoreAndInitialize(
        address implementation,
        bytes32 salt,
        IERC20 asset,
        IStAztec stAztec,
        IStakingManager stakingManager,
        uint256 protocolFeeBP,
        uint256 treasuryFeeSplitBP,
        address governance,
        IRewardsAccumulator rewardsAccumulator,
        address safetyModule
    ) external returns (address proxy) {
        if (implementation == address(0)) {
            revert AtomicProxyFactory__ZeroAddress("implementation");
        }

        proxy = address(new ERC1967Proxy{ salt: salt }(implementation, ""));
        OllaCore(proxy)
            .initialize(
                asset,
                stAztec,
                stakingManager,
                protocolFeeBP,
                treasuryFeeSplitBP,
                governance,
                rewardsAccumulator,
                safetyModule
            );

        return proxy;
    }

    function deployVaultAndInitialize(
        address implementation,
        bytes32 salt,
        IERC20 asset,
        IStAztec stAztec,
        address withdrawalQueue,
        address core,
        address governance
    ) external returns (address proxy) {
        if (implementation == address(0)) {
            revert AtomicProxyFactory__ZeroAddress("implementation");
        }

        proxy = address(new ERC1967Proxy{ salt: salt }(implementation, ""));
        OllaVault(proxy).initialize(asset, stAztec, withdrawalQueue, core, governance);

        return proxy;
    }

    function computeAddress(address implementation, bytes32 salt) external view returns (address) {
        if (implementation == address(0)) {
            revert AtomicProxyFactory__ZeroAddress("implementation");
        }

        bytes memory creationCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, ""));
        return Create2.computeAddress(salt, keccak256(creationCode), address(this));
    }
}
