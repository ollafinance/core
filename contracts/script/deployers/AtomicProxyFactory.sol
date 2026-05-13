// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Create2 } from "@oz/utils/Create2.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { OllaVault } from "src/vault/OllaVault.sol";

/// @title AtomicProxyFactory
/// @notice Deploys ERC1967 proxies and initializes them in the same transaction.
contract AtomicProxyFactory {
    address public immutable DEPLOYER;

    error AtomicProxyFactory__ZeroAddress(string arg);
    error AtomicProxyFactory__UnauthorizedCaller(address caller);

    modifier onlyDeployer() {
        if (msg.sender != DEPLOYER) {
            revert AtomicProxyFactory__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    constructor(address deployer_) {
        if (deployer_ == address(0)) {
            revert AtomicProxyFactory__ZeroAddress("deployer");
        }
        DEPLOYER = deployer_;
    }

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
    ) external onlyDeployer returns (address proxy) {
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
        address core,
        address governance
    ) external onlyDeployer returns (address proxy) {
        if (implementation == address(0)) {
            revert AtomicProxyFactory__ZeroAddress("implementation");
        }

        proxy = address(new ERC1967Proxy{ salt: salt }(implementation, ""));
        OllaVault(proxy).initialize(asset, stAztec, core, governance);

        return proxy;
    }

    /// @notice Deploys the StakingManager and StakingProviderRegistry proxies AND initializes
    /// both in a single transaction, closing the front-run window inherent to deploying a
    /// circular pair as two separate transactions.
    /// @dev The two contracts reference each other at initialize-time. Both proxies are created
    /// here with empty init data so that each can be initialized with the other's address once
    /// both addresses exist; because the deploy-and-init sequence executes inside this external
    /// call, the proxies never have an observable uninitialized window.
    function deployStakingPairAndInitialize(
        address stakingManagerImpl,
        address stakingProviderRegistryImpl,
        bytes32 stakingManagerSalt,
        bytes32 stakingProviderRegistrySalt,
        IERC20 asset,
        address rollupRegistry,
        IRewardsAccumulator rewardsAccumulator,
        address core,
        address providerAdmin,
        address providerRewardsRecipient,
        address governanceAdmin
    ) external onlyDeployer returns (address stakingManagerProxy, address stakingProviderRegistryProxy) {
        if (stakingManagerImpl == address(0)) {
            revert AtomicProxyFactory__ZeroAddress("stakingManagerImpl");
        }
        if (stakingProviderRegistryImpl == address(0)) {
            revert AtomicProxyFactory__ZeroAddress("stakingProviderRegistryImpl");
        }

        stakingManagerProxy = address(new ERC1967Proxy{ salt: stakingManagerSalt }(stakingManagerImpl, ""));
        stakingProviderRegistryProxy =
            address(new ERC1967Proxy{ salt: stakingProviderRegistrySalt }(stakingProviderRegistryImpl, ""));

        IStakingProviderRegistry(stakingProviderRegistryProxy)
            .initialize(stakingManagerProxy, providerAdmin, providerRewardsRecipient, governanceAdmin);

        IStakingManager(stakingManagerProxy)
            .initialize(
                asset, rollupRegistry, address(rewardsAccumulator), core, stakingProviderRegistryProxy, governanceAdmin
            );

        return (stakingManagerProxy, stakingProviderRegistryProxy);
    }

    function computeAddress(address implementation, bytes32 salt) external view returns (address) {
        if (implementation == address(0)) {
            revert AtomicProxyFactory__ZeroAddress("implementation");
        }

        bytes memory creationCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, ""));
        return Create2.computeAddress(salt, keccak256(creationCode), address(this));
    }
}
