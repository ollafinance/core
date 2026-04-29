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
            protocolFeeBP: 500,
            treasuryFeeSplitBP: 5000,
            // Governance config
            governance: vm.envOr("GOVERNANCE", deployer),
            treasury: vm.envOr("TREASURY", deployer),
            providerAdmin: vm.envOr("PROVIDER_ADMIN", deployer),
            guardian: vm.envOr("GUARDIAN", deployer),
            timelockMinDelay: timelockDuration,
            // Satellite addresses - populated during deployment
            rewardsAccumulator: deployer,
            safetyModule: deployer
        });
    }
}
