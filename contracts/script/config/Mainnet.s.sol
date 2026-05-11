// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ConfigHelper, DeployConfig } from "./Config.s.sol";

/// @title MainnetConfig
/// @notice Configuration for Ethereum mainnet deployment
contract MainnetConfig is ConfigHelper {
    /// @notice Ethereum mainnet chain ID
    uint256 internal constant _MAINNET_CHAIN_ID = 1;

    function getConfig() external view override returns (DeployConfig memory) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        bool mockAztec = vm.envOr("MOCK_AZTEC", false);
        if (mockAztec) {
            revert("MainnetConfig: MOCK_AZTEC=true is forbidden on mainnet");
        }

        bool providerKeyCountDefined = vm.envExists("PROVIDER_KEY_COUNT");
        if (providerKeyCountDefined) {
            revert("MainnetConfig: PROVIDER_KEY_COUNT is not supported on mainnet");
        }

        uint256 timelockDuration = vm.envOr("TIMELOCK_DURATION", uint256(172800));

        bool lzEndpointDefined = vm.envExists("LZ_ENDPOINT");
        if (!lzEndpointDefined) {
            revert("MainnetConfig: LZ_ENDPOINT must be defined");
        }
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");

        return DeployConfig({
            // Network
            name: "mainnet",
            chainId: _MAINNET_CHAIN_ID,
            // Deployer
            deployerPrivateKey: deployerPrivateKey,
            deployer: deployer,
            // Feature flags
            deployMocks: false,
            // Bridge configuration
            lzEndpointDefined: lzEndpointDefined,
            lzEndpoint: lzEndpoint,
            // External addresses
            asset: vm.envAddress("ASSET"),
            rollupRegistry: vm.envAddress("ROLLUP_REGISTRY"),
            // Protocol fee config
            protocolFeeBP: vm.envOr("PROTOCOL_FEE_BP", uint256(1000)),
            treasuryFeeSplitBP: vm.envOr("TREASURY_FEE_SPLIT_BP", uint256(5000)),
            // Safety module config
            safetyDepositCap: vm.envOr("SAFETY_DEPOSIT_CAP", uint256(100_000_000e18)),
            safetyMinRateDropBps: vm.envOr("SAFETY_MIN_RATE_DROP_BPS", uint256(500)),
            safetyMaxQueueRatioBps: vm.envOr("SAFETY_MAX_QUEUE_RATIO_BPS", uint256(2_500)),
            safetyMaxAccountingDelay: vm.envOr("SAFETY_MAX_ACCOUNTING_DELAY", uint256(48 hours)),
            // Governance config
            governance: vm.envAddress("GOVERNANCE"),
            treasury: vm.envAddress("TREASURY"),
            providerAdmin: vm.envAddress("PROVIDER_ADMIN"),
            providerRewardsRecipient: vm.envOr("PROVIDER_REWARDS_RECIPIENT", vm.envAddress("TREASURY")),
            guardian: vm.envAddress("GUARDIAN"),
            timelockMinDelay: timelockDuration,
            // Satellite addresses - populated during deployment
            rewardsAccumulator: deployer,
            safetyModule: deployer
        });
    }
}
