// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script } from "@forge-std/Script.sol";

/// @notice Deployment configuration struct
struct DeployConfig {
    // Environment info
    string name;
    uint256 chainId;
    // Deployer
    uint256 deployerPrivateKey;
    address deployer;
    // Feature flags
    bool deployMocks;
    // External addresses (used when deployMocks is false)
    address asset;
    address stakingManager;
    // Protocol fee config
    uint256 protocolFeeBP;
    uint256 treasuryFeeSplitBP;
    // Governance addresses
    address governance;
    address withdrawalQueue;
    address rewardsVault;
    address safetyModule;
}

/// @title ConfigHelper
/// @author Olla
/// @notice Helper to load the correct config based on DEPLOY_ENV
abstract contract ConfigHelper is Script {
    /// @notice Load config based on DEPLOY_ENV environment variable
    /// @dev Override this in child configs
    /// @return The deployment configuration
    function getConfig() external virtual returns (DeployConfig memory);

    /// @notice Get environment name from DEPLOY_ENV, defaults to "local"
    /// @return The environment name string
    function _getEnvName() internal view returns (string memory) {
        return vm.envOr("DEPLOY_ENV", string("local"));
    }

    /// @notice Check if current environment matches the given name
    /// @param env The environment name to check
    /// @return True if the current environment matches
    function _isEnv(string memory env) internal view returns (bool) {
        return keccak256(bytes(_getEnvName())) == keccak256(bytes(env));
    }
}
