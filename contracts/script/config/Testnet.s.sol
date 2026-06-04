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
        if (!vm.envExists("MOCK_AZTEC")) {
            revert("TestnetConfig: MOCK_AZTEC must be explicitly set");
        }
        bool mockAztec = vm.envBool("MOCK_AZTEC");
        bool providerKeyCountDefined = vm.envExists("PROVIDER_KEY_COUNT");
        if (!mockAztec && providerKeyCountDefined) {
            revert("TestnetConfig: PROVIDER_KEY_COUNT is not supported when MOCK_AZTEC=false");
        }

        uint256 timelockDuration = vm.envOr("TIMELOCK_DURATION", uint256(3600));
        bool lzEndpointDefined = vm.envExists("LZ_ENDPOINT");
        if (!lzEndpointDefined) {
            revert("TestnetConfig: LZ_ENDPOINT must be defined");
        }
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        // Strict non-mock Sepolia requires a real bridge endpoint; mock Sepolia may run bridge-less.
        if (!mockAztec) {
            require(lzEndpoint != address(0), "TestnetConfig: LZ_ENDPOINT must be nonzero when MOCK_AZTEC=false");
        }

        return DeployConfig({
            // Network
            name: "sepolia",
            chainId: _SEPOLIA_CHAIN_ID,
            // Deployer
            deployerPrivateKey: deployerPrivateKey,
            deployer: deployer,
            // Feature flags
            deployMocks: mockAztec,
            // Bridge configuration
            lzEndpointDefined: lzEndpointDefined,
            lzEndpoint: lzEndpoint,
            // External addresses - required when MOCK_AZTEC=false
            asset: vm.envOr("ASSET", address(0)),
            rollupRegistry: vm.envOr("ROLLUP_REGISTRY", address(0)),
            // Protocol fee config
            protocolFeeBP: vm.envOr("PROTOCOL_FEE_BP", uint256(500)),
            treasuryFeeSplitBP: vm.envOr("TREASURY_FEE_SPLIT_BP", uint256(5000)),
            // Safety module config
            safetyDepositCap: vm.envOr("SAFETY_DEPOSIT_CAP", uint256(1_000_000_000e18)),
            safetyMinRateDropBps: vm.envOr("SAFETY_MIN_RATE_DROP_BPS", uint256(500)),
            safetyMaxQueueRatioBps: vm.envOr("SAFETY_MAX_QUEUE_RATIO_BPS", uint256(5_000)),
            safetyMaxAccountingDelay: vm.envOr("SAFETY_MAX_ACCOUNTING_DELAY", uint256(2 hours)),
            // Governance config
            governance: vm.envOr("GOVERNANCE", deployer),
            treasury: vm.envOr("TREASURY", deployer),
            providerAdmin: vm.envOr("PROVIDER_ADMIN", deployer),
            providerRewardsRecipient: vm.envOr("PROVIDER_REWARDS_RECIPIENT", vm.envOr("PROVIDER_ADMIN", deployer)),
            guardian: vm.envOr("GUARDIAN", deployer),
            timelockMinDelay: timelockDuration,
            // Satellite addresses - populated during deployment
            rewardsAccumulator: deployer,
            safetyModule: deployer
        });
    }
}
