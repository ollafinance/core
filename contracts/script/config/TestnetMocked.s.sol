// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ConfigHelper, DeployConfig } from "./Config.s.sol";

/// @title TestnetMockedConfig
/// @notice Configuration for testnet deployment with mocked Aztec contracts (e.g., Sepolia)
contract TestnetMockedConfig is ConfigHelper {
    /// @notice Sepolia chain ID
    uint256 internal constant _SEPOLIA_CHAIN_ID = 11155111;

    function getConfig() external view override returns (DeployConfig memory) {
        // Private key must be provided via environment variable for testnet
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        return DeployConfig({
            // Environment
            name: "testnet-mocked",
            chainId: _SEPOLIA_CHAIN_ID,
            // Deployer
            deployerPrivateKey: deployerPrivateKey,
            deployer: deployer,
            // Feature flags - deploy mocks for mocked testnet
            deployMocks: true,
            // External addresses - populated by mock deployer
            asset: address(0),
            rollupRegistry: address(0),
            // Protocol fee config
            protocolFeeBP: 500,
            treasuryFeeSplitBP: 5000,
            // Governance config
            governance: deployer,
            treasury: deployer,
            providerAdmin: deployer,
            timelockMinDelay: 0, // zero for mocked testnet — allows atomic wiring
            // Satellite addresses - populated during deployment
            withdrawalQueue: deployer,
            rewardsAccumulator: deployer,
            safetyModule: deployer
        });
    }
}
