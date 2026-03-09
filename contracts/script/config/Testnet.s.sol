// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ConfigHelper, DeployConfig } from "./Config.s.sol";

/// @title TestnetConfig
/// @notice Configuration for testnet deployment (e.g., Sepolia)
contract TestnetConfig is ConfigHelper {
    /// @notice Sepolia chain ID
    uint256 internal constant _SEPOLIA_CHAIN_ID = 11155111;

    function getConfig() external view override returns (DeployConfig memory) {
        // Private key must be provided via environment variable for testnet
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        return DeployConfig({
            // Environment
            name: "testnet",
            chainId: _SEPOLIA_CHAIN_ID,
            // Deployer
            deployerPrivateKey: deployerPrivateKey,
            deployer: deployer,
            // Feature flags - do NOT deploy mocks on testnet
            deployMocks: false,
            // External addresses - real Aztec Sepolia contracts
            asset: 0x5595cb9ED193cAc2C0Bc5393313bc6115817954B,
            rollupRegistry: 0xA0BFb1B494FB49041e5c6e8c2C1BE09cD171c6Ba,
            // Protocol fee config
            protocolFeeBP: 500,
            treasuryFeeSplitBP: 5000,
            // Governance config - TODO: replace with real addresses
            governance: deployer, // TODO: Set real governance multisig
            treasury: deployer, // TODO: Set real treasury address
            providerAdmin: deployer, // TODO: Set real provider admin address
            timelockMinDelay: 0, // zero for initial testnet — allows atomic wiring
            // Satellite addresses - populated during deployment
            withdrawalQueue: deployer,
            rewardsAccumulator: deployer,
            safetyModule: deployer
        });
    }
}
