// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { EndpointV2Mock } from "@lz-test/contracts/mocks/EndpointV2Mock.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
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

    /// @notice Deploy a mock LayerZero V2 endpoint for local development.
    /// @param config The deployment configuration
    /// @param eid The endpoint ID to assign (e.g. 1 for home chain)
    /// @return lzEndpoint The deployed EndpointV2Mock address
    function deployLzEndpointMock(DeployConfig memory config, uint32 eid) external returns (address lzEndpoint) {
        require(config.deployMocks, "MocksDeployer: mocks not enabled for this environment");

        vm.startBroadcast(config.deployerPrivateKey);

        EndpointV2Mock endpoint = new EndpointV2Mock(eid, config.deployer);
        _logDeployment("EndpointV2Mock", address(endpoint));

        vm.stopBroadcast();

        return address(endpoint);
    }
}
