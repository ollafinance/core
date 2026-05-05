// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";

/// @title StakingStackDeployer
/// @notice Deploys the StakingManager and StakingProviderRegistry behind proxies
contract StakingStackDeployer is BaseDeployer {
    /// @notice Deploy and initialize the staking stack behind proxies.
    /// @dev Proxies are deployed uninitialized to break the circular dependency.
    function deploy(
        DeployConfig memory config,
        address core,
        address rewardsAccumulator,
        address asset,
        address rollupRegistry,
        address governanceAdmin
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

        // Deploy implementations
        StakingManager smImpl = new StakingManager();
        _logDeployment("StakingManager Implementation", address(smImpl));

        StakingProviderRegistry sprImpl = new StakingProviderRegistry();
        _logDeployment("StakingProviderRegistry Implementation", address(sprImpl));

        // Deploy proxies (uninitialized)
        ERC1967Proxy smProxy = new ERC1967Proxy(address(smImpl), "");
        _logDeployment("StakingManager Proxy", address(smProxy));

        ERC1967Proxy sprProxy = new ERC1967Proxy(address(sprImpl), "");
        _logDeployment("StakingProviderRegistry Proxy", address(sprProxy));

        // Cache all values to minimize stack usage
        address providerAdmin = config.providerAdmin;
        address providerRewardsRecipient = config.providerRewardsRecipient;
        address smProxyAddr = address(smProxy);
        address sprProxyAddr = address(sprProxy);

        // Initialize StakingProviderRegistry first (needs stakingManager address)
        // defaultAdmin is governance so OllaGovernance can propagate admin role changes.
        StakingProviderRegistry(sprProxyAddr)
            .initialize(smProxyAddr, providerAdmin, providerRewardsRecipient, governanceAdmin);

        // Initialize StakingManager
        // defaultAdmin is governance so OllaGovernance can propagate admin role changes.
        StakingManager(smProxyAddr)
            .initialize(IERC20(asset), rollupRegistry, rewardsAccumulator, core, sprProxyAddr, governanceAdmin);

        vm.stopBroadcast();

        return (address(smImpl), smProxyAddr, address(sprImpl), sprProxyAddr);
    }
}
