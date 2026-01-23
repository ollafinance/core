// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { BaseDeployer, console2 } from "../base/BaseDeployer.s.sol";
import { DeployConfig } from "../config/Config.s.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockStakingManager } from "src/mocks/MockStakingManager.sol";

/// @title MocksDeployer
/// @notice Deploys mock contracts for local development
contract MocksDeployer is BaseDeployer {
    /// @notice Deploy all mock contracts
    /// @param config The deployment configuration
    /// @return asset The deployed MockAztec address
    /// @return stakingManager The deployed MockStakingManager address
    function deploy(DeployConfig memory config) external returns (address asset, address stakingManager) {
        require(config.deployMocks, "MocksDeployer: mocks not enabled for this environment");

        vm.startBroadcast(config.deployerPrivateKey);

        // Deploy MockAztec
        MockAztec mockAsset = new MockAztec(config.deployer);
        _logDeployment("MockAztec", address(mockAsset));

        // Deploy MockStakingManager
        MockStakingManager mockStakingManager = new MockStakingManager();
        _logDeployment("MockStakingManager", address(mockStakingManager));

        // Mint initial tokens to deployer for testing
        mockAsset.mint(config.deployer, 1000 ether);
        console2.log("Minted 1000 MockAztec tokens to deployer");

        vm.stopBroadcast();

        return (address(mockAsset), address(mockStakingManager));
    }
}
