// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";

/// @title MocksDeployer
/// @notice Deploys mock contracts for local development
contract MocksDeployer is BaseDeployer {
    /// @notice Deploy the local staking asset and Aztec-side mocks.
    /// @dev Returns rollup + registry so local deploy can wire the real staking stack.
    function deployAssetAndRollup(DeployConfig memory config)
        external
        returns (address asset, address rollup, address rollupRegistry)
    {
        require(config.deployMocks, "MocksDeployer: mocks not enabled for this environment");

        vm.startBroadcast(config.deployerPrivateKey);

        MockAztec mockAsset = new MockAztec(config.deployer);
        _logDeployment("MockAztec", address(mockAsset));

        // Pass 0 to use MockAztecRollup.DEFAULT_ACTIVATION_THRESHOLD internally.
        MockAztecRollup mockRollup = new MockAztecRollup(IERC20(address(mockAsset)), 0);
        _logDeployment("MockAztecRollup", address(mockRollup));

        MockAztecRollupRegistry registry = new MockAztecRollupRegistry(address(mockRollup));
        _logDeployment("MockAztecRollupRegistry", address(registry));

        // Mint initial tokens to deployer for local testing.
        mockAsset.mint(config.deployer, 1000 ether);

        vm.stopBroadcast();

        return (address(mockAsset), address(mockRollup), address(registry));
    }

    /// @notice Deploy and initialize the real staking stack behind proxies.
    /// @dev Proxies are deployed uninitialized to break the circular dependency.
    function deployStakingStack(
        DeployConfig memory config,
        address core,
        address rewardsVault,
        address asset,
        address rollupRegistry
    )
        external
        returns (
            address stakingManagerImpl,
            address stakingManagerProxy,
            address stakingProviderRegistryImpl,
            address stakingProviderRegistryProxy
        )
    {
        require(config.deployMocks, "MocksDeployer: mocks not enabled for this environment");
        require(core != address(0), "MocksDeployer: core required");
        require(rewardsVault != address(0), "MocksDeployer: rewardsVault required");
        require(asset != address(0), "MocksDeployer: asset required");
        require(rollupRegistry != address(0), "MocksDeployer: rollupRegistry required");

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

        // Initialize StakingProviderRegistry first (needs stakingManager address)
        StakingProviderRegistry(address(sprProxy))
            .initialize(address(smProxy), config.deployer, config.deployer, config.deployer);

        // Initialize StakingManager
        StakingManager(address(smProxy))
            .initialize(IERC20(asset), rollupRegistry, rewardsVault, core, address(sprProxy), config.deployer);

        vm.stopBroadcast();

        return (address(smImpl), address(smProxy), address(sprImpl), address(sprProxy));
    }
}
