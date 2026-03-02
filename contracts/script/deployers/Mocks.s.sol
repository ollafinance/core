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
    /// @notice Struct to avoid stack too deep in deployStakingStack
    struct StakingStackParams {
        DeployConfig config;
        address core;
        address rewardsCollector;
        address asset;
        address rollupRegistry;
        address governance;
    }

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
        address rewardsCollector,
        address asset,
        address rollupRegistry,
        address governance
    )
        external
        returns (
            address stakingManagerImpl,
            address stakingManagerProxy,
            address stakingProviderRegistryImpl,
            address stakingProviderRegistryProxy
        )
    {
        StakingStackParams memory params = StakingStackParams({
            config: config,
            core: core,
            rewardsCollector: rewardsCollector,
            asset: asset,
            rollupRegistry: rollupRegistry,
            governance: governance
        });

        return _deployStakingStackInternal(params);
    }

    /// @notice Internal implementation to avoid stack too deep
    function _deployStakingStackInternal(StakingStackParams memory params)
        internal
        returns (
            address stakingManagerImpl,
            address stakingManagerProxy,
            address stakingProviderRegistryImpl,
            address stakingProviderRegistryProxy
        )
    {
        require(params.config.deployMocks, "MocksDeployer: mocks not enabled for this environment");
        require(params.core != address(0), "MocksDeployer: core required");
        require(params.rewardsCollector != address(0), "MocksDeployer: rewardsCollector required");
        require(params.asset != address(0), "MocksDeployer: asset required");
        require(params.rollupRegistry != address(0), "MocksDeployer: rollupRegistry required");
        require(params.governance != address(0), "MocksDeployer: governance required");

        vm.startBroadcast(params.config.deployerPrivateKey);

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
        address deployer = params.config.deployer;
        address smProxyAddr = address(smProxy);
        address sprProxyAddr = address(sprProxy);
        IERC20 asset = IERC20(params.asset);
        address rollupRegistry = params.rollupRegistry;
        address rewardsCollector = params.rewardsCollector;
        address core = params.core;

        address governance = params.governance;

        // Initialize StakingProviderRegistry first (needs stakingManager address)
        // defaultAdmin is governance so OllaGovernance can propagate admin role changes.
        StakingProviderRegistry(sprProxyAddr).initialize(smProxyAddr, deployer, deployer, governance);

        // Initialize StakingManager
        // defaultAdmin is governance so OllaGovernance can propagate admin role changes.
        StakingManager(smProxyAddr).initialize(asset, rollupRegistry, rewardsCollector, core, sprProxyAddr, governance);

        vm.stopBroadcast();

        return (address(smImpl), smProxyAddr, address(sprImpl), sprProxyAddr);
    }
}
