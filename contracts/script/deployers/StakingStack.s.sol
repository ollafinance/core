// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";
import { AtomicProxyFactory } from "./AtomicProxyFactory.sol";

/// @title StakingStackDeployer
/// @notice Deploys the StakingManager and StakingProviderRegistry behind proxies
contract StakingStackDeployer is BaseDeployer {
    AtomicProxyFactory internal immutable _PROXY_FACTORY;

    constructor(AtomicProxyFactory proxyFactory_) {
        _PROXY_FACTORY = proxyFactory_;
    }

    /// @notice Deploy and initialize the staking stack behind proxies.
    /// @dev Proxy creation and both initialize() calls execute inside a single external call to
    /// the factory, so the circular pair never has an observable uninitialized window.
    function deploy(
        DeployConfig memory config,
        address core,
        address rewardsAccumulator,
        address asset,
        address rollupRegistry,
        address governanceAdmin,
        bytes32 stakingManagerSalt,
        bytes32 stakingProviderRegistrySalt
    )
        external
        returns (
            address stakingManagerImpl,
            address stakingManagerProxy,
            address stakingProviderRegistryImpl,
            address stakingProviderRegistryProxy
        )
    {
        require(core != address(0), "StakingStackDeployer: core required");
        require(rewardsAccumulator != address(0), "StakingStackDeployer: rewardsAccumulator required");
        require(asset != address(0), "StakingStackDeployer: asset required");
        require(rollupRegistry != address(0), "StakingStackDeployer: rollupRegistry required");
        require(governanceAdmin != address(0), "StakingStackDeployer: governanceAdmin required");

        vm.startBroadcast(config.deployerPrivateKey);

        // Deploy implementations. Implementations have no admin and no storage of interest, so
        // running them as two separate transactions is fine. The vulnerable step is the proxy
        // pair, which the factory handles atomically below.
        StakingManager smImpl = new StakingManager();
        _logDeployment("StakingManager Implementation", address(smImpl));

        StakingProviderRegistry sprImpl = new StakingProviderRegistry();
        _logDeployment("StakingProviderRegistry Implementation", address(sprImpl));

        (stakingManagerProxy, stakingProviderRegistryProxy) = _PROXY_FACTORY.deployStakingPairAndInitialize(
            address(smImpl),
            address(sprImpl),
            stakingManagerSalt,
            stakingProviderRegistrySalt,
            IERC20(asset),
            rollupRegistry,
            IRewardsAccumulator(rewardsAccumulator),
            core,
            config.providerAdmin,
            config.providerRewardsRecipient,
            governanceAdmin
        );
        _logDeployment("StakingManager Proxy", stakingManagerProxy);
        _logDeployment("StakingProviderRegistry Proxy", stakingProviderRegistryProxy);

        vm.stopBroadcast();

        return (address(smImpl), stakingManagerProxy, address(sprImpl), stakingProviderRegistryProxy);
    }

    function predictStakingManagerProxy(address implementation, bytes32 salt) external view returns (address) {
        return _PROXY_FACTORY.computeAddress(implementation, salt);
    }

    function predictStakingProviderRegistryProxy(address implementation, bytes32 salt) external view returns (address) {
        return _PROXY_FACTORY.computeAddress(implementation, salt);
    }
}
