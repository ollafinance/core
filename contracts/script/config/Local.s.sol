// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ConfigHelper, DeployConfig } from "./Config.s.sol";

/// @title LocalConfig
/// @notice Configuration for local Anvil deployment
contract LocalConfig is ConfigHelper {
    /// @notice Default Anvil private key (account 0)
    uint256 internal constant _ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// @notice Anvil chain ID
    uint256 internal constant _ANVIL_CHAIN_ID = 31337;

    function getConfig() external view override returns (DeployConfig memory) {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", _ANVIL_PRIVATE_KEY);
        address deployer = vm.addr(deployerPrivateKey);

        return DeployConfig({
            // Environment
            name: "local",
            chainId: _ANVIL_CHAIN_ID,
            // Deployer
            deployerPrivateKey: deployerPrivateKey,
            deployer: deployer,
            // Feature flags - deploy mocks for local development
            deployMocks: true,
            // External addresses - not used in local (mocks deployed instead)
            asset: address(0),
            stakingManager: address(0),
            // Protocol fee config
            protocolFeeBP: 500,
            treasuryFeeSplitBP: 5000,
            // Governance config - deployer acts as governance admin for local dev
            governance: deployer,
            treasury: deployer,
            timelockMinDelay: 0, // instant for local dev
            // Satellite addresses - populated during deployment
            withdrawalQueue: deployer,
            rewardsVault: deployer,
            safetyModule: deployer
        });
    }
}
