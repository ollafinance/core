// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ConfigHelper, DeployConfig } from "./Config.s.sol";

/// @title TestnetConfig
/// @notice Configuration for testnet deployment (e.g., Sepolia)
contract TestnetConfig is ConfigHelper {
    /// @notice Sepolia chain ID
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    function getConfig() external view override returns (DeployConfig memory) {
        // Private key must be provided via environment variable for testnet
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        return DeployConfig({
            // Environment
            name: "testnet",
            chainId: SEPOLIA_CHAIN_ID,
            // Deployer
            deployerPrivateKey: deployerPrivateKey,
            deployer: deployer,
            // Feature flags - do NOT deploy mocks on testnet
            deployMocks: false,
            // External addresses - TODO: replace with real addresses
            asset: address(0), // TODO: Set real asset address
            stakingManager: address(0), // TODO: Set real staking manager address
            // Protocol fee config - TODO: set real values
            protocolFeeBP: 0,
            treasuryFeeSplitBP: 0,
            // Governance addresses - TODO: replace with real addresses
            governance: deployer, // TODO: Set real governance address
            withdrawalQueue: deployer, // TODO: Set real withdrawal queue address
            rewardsVault: deployer, // TODO: Set real rewards vault address
            safetyModule: deployer // TODO: Set real safety module address
        });
    }
}
