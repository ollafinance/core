// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script } from "@forge-std/Script.sol";

/// @notice Deployment configuration struct
struct DeployConfig {
    // Network info
    string name;
    uint256 chainId;
    // Deployer
    uint256 deployerPrivateKey;
    address deployer;
    // Feature flags
    bool deployMocks;
    // Bridge configuration
    bool lzEndpointDefined;
    address lzEndpoint;
    // External addresses (used when deployMocks is false)
    address asset;
    address rollupRegistry;
    // Protocol fee config
    uint256 protocolFeeBP;
    uint256 treasuryFeeSplitBP;
    // Safety module config
    uint256 safetyDepositCap;
    uint256 safetyMinRateDropBps;
    uint256 safetyMaxQueueRatioBps;
    uint256 safetyMaxAccountingDelay;
    // Governance config
    address governance; // EOA/multisig that controls OllaGovernance
    address treasury; // fee recipient
    address providerAdmin; // StakingProviderRegistry provider admin + rewards recipient
    address providerRewardsRecipient; // StakingProviderRegistry provider rewards recipient
    address guardian; // SafetyModule guardian
    uint256 timelockMinDelay; // minimum timelock delay in seconds
    // Satellite addresses (populated during deployment)
    address rewardsAccumulator;
    address safetyModule;
}

/// @title ConfigHelper
/// @author Olla
/// @notice Helper to load deployment configuration.
abstract contract ConfigHelper is Script {
    /// @notice Load deployment config.
    /// @dev Override this in child configs
    /// @return The deployment configuration
    function getConfig() external virtual returns (DeployConfig memory);
}
