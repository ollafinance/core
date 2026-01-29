// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/Script.sol";
import { BaseDeployer } from "./base/BaseDeployer.s.sol";
import { DeployConfig } from "./config/Config.s.sol";
import { LocalConfig } from "./config/Local.s.sol";
import { TestnetConfig } from "./config/Testnet.s.sol";
import { MocksDeployer } from "./deployers/Mocks.s.sol";
import { OllaCoreDeployer } from "./deployers/OllaCore.s.sol";
import { StAztecDeployer } from "./deployers/StAztec.s.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { StAztec } from "src/core/StAztec.sol";
import { IERC5267 } from "@oz/interfaces/IERC5267.sol";

/// @title DeployScript
/// @notice Main deployment orchestrator - deploys all contracts based on environment
contract DeployScript is BaseDeployer {
    // Deployers
    MocksDeployer internal mocksDeployer;
    OllaCoreDeployer internal ollaCoreDeployer;
    StAztecDeployer internal stAztecDeployer;

    function setUp() public {
        // Initialize deployers
        mocksDeployer = new MocksDeployer();
        ollaCoreDeployer = new OllaCoreDeployer();
        stAztecDeployer = new StAztecDeployer();
    }

    function run() public {
        // Load config based on DEPLOY_ENV
        DeployConfig memory config = _loadConfig();

        console2.log("===========================================");
        console2.log("Deploying to:", config.name);
        console2.log("Chain ID:", config.chainId);
        console2.log("Deployer:", config.deployer);
        console2.log("Deploy Mocks:", config.deployMocks);
        console2.log("===========================================");

        // Track deployed addresses
        address asset;
        address stakingManager;
        address ollaCoreImpl;
        address ollaCoreProxy;
        address stAztec;
        address safetyModule;

        // Initialize deployment JSON
        string memory json = _initDeploymentJson(config.name, config.chainId, config.deployer);
        bool isFirstAddress = true;

        // 1. Deploy or use existing mocks/external contracts
        if (config.deployMocks) {
            console2.log("\n--- Deploying Mocks ---");
            (asset, stakingManager) = mocksDeployer.deploy(config);

            // Local safety module stub: allows deposits/withdrawals without role setup.
            vm.startBroadcast(config.deployerPrivateKey);
            safetyModule = address(new MockSafetyModule());
            vm.stopBroadcast();
            _logDeployment("MockSafetyModule", safetyModule);
        } else {
            console2.log("\n--- Using External Contracts ---");
            asset = config.asset;
            stakingManager = config.stakingManager;
            safetyModule = config.safetyModule;
            require(asset != address(0), "Deploy: asset address required for non-mock deployment");
            require(stakingManager != address(0), "Deploy: stakingManager address required for non-mock deployment");
            require(safetyModule != address(0), "Deploy: safetyModule address required for non-mock deployment");
        }

        // Always write Asset and StakingManager to JSON (regardless of mock or real)
        console2.log("Asset:", asset);
        console2.log("StakingManager:", stakingManager);
        json = _addAddressToJson(json, "Asset", asset, isFirstAddress);
        isFirstAddress = false;
        json = _addAddressToJson(json, "StakingManager", stakingManager, false);

        // 2. Deploy OllaCore (implementation + proxy)
        console2.log("\n--- Deploying OllaCore ---");
        (ollaCoreImpl, ollaCoreProxy) = ollaCoreDeployer.deploy(config);
        json = _addAddressToJson(json, "OllaCoreImplementation", ollaCoreImpl, isFirstAddress);
        if (isFirstAddress) isFirstAddress = false;
        json = _addAddressToJson(json, "OllaCoreProxy", ollaCoreProxy, false);

        // 3. Deploy StAztec (linked to OllaCore proxy)
        console2.log("\n--- Deploying StAztec ---");
        stAztec = stAztecDeployer.deploy(config, ollaCoreProxy);
        json = _addAddressToJson(json, "StAztec", stAztec, false);

        // Safety module (required by OllaCore deposit/withdraw paths)
        json = _addAddressToJson(json, "SafetyModule", safetyModule, false);

        // 4. Initialize OllaCore with all dependencies
        console2.log("\n--- Initializing OllaCore ---");
        ollaCoreDeployer.initialize(config, ollaCoreProxy, asset, stAztec, stakingManager, safetyModule);

        // 5. Write deployment JSON
        json = _closeAddressesJson(json);

        // Add StAztec metadata for frontend signature generation
        string memory stAztecName = StAztec(stAztec).name();

        // Get version from EIP712 domain
        (,, string memory stAztecVersion,,,,) = IERC5267(stAztec).eip712Domain();

        json = _addMetadataToJson(json, "stAztecName", stAztecName);
        json = _addMetadataToJson(json, "stAztecVersion", stAztecVersion);

        _writeDeploymentJson(config.name, json);

        console2.log("\n===========================================");
        console2.log("Deployment complete!");
        console2.log("===========================================");
    }

    /// @notice Load the appropriate config based on DEPLOY_ENV
    function _loadConfig() internal returns (DeployConfig memory) {
        string memory env = vm.envOr("DEPLOY_ENV", string("local"));

        if (keccak256(bytes(env)) == keccak256(bytes("local"))) {
            LocalConfig localConfig = new LocalConfig();
            return localConfig.getConfig();
        } else if (keccak256(bytes(env)) == keccak256(bytes("testnet"))) {
            TestnetConfig testnetConfig = new TestnetConfig();
            return testnetConfig.getConfig();
        } else {
            revert(string.concat("Unknown DEPLOY_ENV: ", env));
        }
    }
}
