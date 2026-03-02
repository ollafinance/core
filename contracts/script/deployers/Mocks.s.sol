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
        address rewardsAccumulator;
        address asset;
        address rollupRegistry;
        address governanceAdmin;
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

        // Mint initial tokens to all 10 default Anvil accounts for local testing.
        mockAsset.mint(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, 10_000_000 ether);
        mockAsset.mint(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 10_000_000 ether);
        mockAsset.mint(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, 10_000_000 ether);
        mockAsset.mint(0x90F79bf6EB2c4f870365E785982E1f101E93b906, 10_000_000 ether);
        mockAsset.mint(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65, 10_000_000 ether);
        mockAsset.mint(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc, 10_000_000 ether);
        mockAsset.mint(0x976EA74026E726554dB657fA54763abd0C3a0aa9, 10_000_000 ether);
        mockAsset.mint(0x14dC79964da2C08b23698B3D3cc7Ca32193d9955, 10_000_000 ether);
        mockAsset.mint(0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f, 10_000_000 ether);
        mockAsset.mint(0xa0Ee7A142d267C1f36714E4a8F75612F20a79720, 10_000_000 ether);

        vm.stopBroadcast();

        return (address(mockAsset), address(mockRollup), address(registry));
    }

    /// @notice Deploy and initialize the real staking stack behind proxies.
    /// @dev Proxies are deployed uninitialized to break the circular dependency.
    function deployStakingStack(
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
        StakingStackParams memory params = StakingStackParams({
            config: config,
            core: core,
            rewardsAccumulator: rewardsAccumulator,
            asset: asset,
            rollupRegistry: rollupRegistry,
            governanceAdmin: governanceAdmin
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
        require(params.rewardsAccumulator != address(0), "MocksDeployer: rewardsAccumulator required");
        require(params.asset != address(0), "MocksDeployer: asset required");
        require(params.rollupRegistry != address(0), "MocksDeployer: rollupRegistry required");
        require(params.governanceAdmin != address(0), "MocksDeployer: governanceAdmin required");

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
        address governanceAdmin = params.governanceAdmin;
        address smProxyAddr = address(smProxy);
        address sprProxyAddr = address(sprProxy);
        IERC20 asset = IERC20(params.asset);
        address rollupRegistry = params.rollupRegistry;
        address rewardsAccumulator = params.rewardsAccumulator;
        address core = params.core;

        address governance = params.governanceAdmin;

        // Initialize StakingProviderRegistry first (needs stakingManager address)
        // defaultAdmin is governance so OllaGovernance can propagate admin role changes.
        StakingProviderRegistry(sprProxyAddr).initialize(smProxyAddr, deployer, deployer, governanceAdmin);

        // Initialize StakingManager
        // defaultAdmin is governance so OllaGovernance can propagate admin role changes.
        StakingManager(smProxyAddr).initialize(asset, rollupRegistry, rewardsAccumulator, core, sprProxyAddr, governance);

        vm.stopBroadcast();

        return (address(smImpl), smProxyAddr, address(sprImpl), sprProxyAddr);
    }
}
