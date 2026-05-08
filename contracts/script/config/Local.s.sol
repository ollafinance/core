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
        bool mockAztec = vm.envOr("MOCK_AZTEC", true);
        uint256 timelockDuration = vm.envOr("TIMELOCK_DURATION", uint256(0));
        bool lzEndpointDefined = vm.envExists("LZ_ENDPOINT");
        address lzEndpoint = lzEndpointDefined ? vm.envAddress("LZ_ENDPOINT") : address(0);

        return DeployConfig({
            // Network
            name: "local",
            chainId: _ANVIL_CHAIN_ID,
            // Deployer
            deployerPrivateKey: deployerPrivateKey,
            deployer: deployer,
            // Feature flags
            deployMocks: mockAztec,
            // Bridge configuration
            lzEndpointDefined: lzEndpointDefined,
            lzEndpoint: lzEndpoint,
            // External addresses - used when MOCK_AZTEC=false
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
            // Governance config - deployer acts as governance admin for local dev
            governance: deployer,
            treasury: deployer,
            providerAdmin: deployer,
            providerRewardsRecipient: deployer,
            guardian: deployer,
            timelockMinDelay: timelockDuration,
            // Satellite addresses - populated during deployment
            rewardsAccumulator: deployer,
            safetyModule: deployer
        });
    }
}
