// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC5267 } from "@oz/interfaces/IERC5267.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { BaseDeployer } from "./base/BaseDeployer.s.sol";
import { DeployConfig } from "./config/Config.s.sol";
import { LocalConfig } from "./config/Local.s.sol";
import { TestnetConfig } from "./config/Testnet.s.sol";
import { MocksDeployer } from "./deployers/Mocks.s.sol";
import { OllaCoreDeployer } from "./deployers/OllaCore.s.sol";
import { RewardsVaultDeployer } from "./deployers/RewardsVault.s.sol";
import { StAztecDeployer } from "./deployers/StAztec.s.sol";
import { WithdrawalQueueDeployer } from "./deployers/WithdrawalQueue.s.sol";

/// @title DeployScript
/// @notice Main deployment orchestrator - deploys all contracts based on environment
contract DeployScript is BaseDeployer {
    // Deployers
    MocksDeployer internal _mocksDeployer;
    OllaCoreDeployer internal _ollaCoreDeployer;
    StAztecDeployer internal _stAztecDeployer;
    WithdrawalQueueDeployer internal _withdrawalQueueDeployer;
    RewardsVaultDeployer internal _rewardsVaultDeployer;

    function setUp() public {
        // Initialize deployers
        _mocksDeployer = new MocksDeployer();
        _ollaCoreDeployer = new OllaCoreDeployer();
        _stAztecDeployer = new StAztecDeployer();
        _withdrawalQueueDeployer = new WithdrawalQueueDeployer();
        _rewardsVaultDeployer = new RewardsVaultDeployer();
    }

    function run() public {
        // Load config based on DEPLOY_ENV
        DeployConfig memory config = _loadConfig();

        // Track deployed addresses
        address asset;
        address stakingManager;
        address stakingManagerImpl;
        address stakingProviderRegistry;
        address stakingProviderRegistryImpl;
        address rollup;
        address rollupRegistry;
        address ollaCoreImpl;
        address ollaCoreProxy;
        address stAztec;
        address safetyModule;
        address withdrawalQueue;
        address rewardsVault;
        address withdrawalQueueImpl;
        address rewardsVaultImpl;

        // Initialize deployment JSON
        string memory json = _initDeploymentJson(config.name, config.chainId, config.deployer);
        bool isFirstAddress = true;

        // 1. Deploy OllaCore (implementation + proxy)

        (ollaCoreImpl, ollaCoreProxy) = _ollaCoreDeployer.deploy(config);
        json = _addAddressToJson(json, "OllaCoreImplementation", ollaCoreImpl, isFirstAddress);
        if (isFirstAddress) isFirstAddress = false;
        json = _addAddressToJson(json, "OllaCoreProxy", ollaCoreProxy, false);

        // 2. Deploy or use existing mocks/external contracts
        if (config.deployMocks) {
            // Deploy local staking asset + Aztec mocks (rollup + registry)
            (asset, rollup, rollupRegistry) = _mocksDeployer.deployAssetAndRollup(config);
        } else {
            asset = config.asset;
            stakingManager = config.stakingManager;
            safetyModule = config.safetyModule;
            require(asset != address(0), "Deploy: asset address required for non-mock deployment");
            require(stakingManager != address(0), "Deploy: stakingManager address required for non-mock deployment");
            require(safetyModule != address(0), "Deploy: safetyModule address required for non-mock deployment");
        }

        // Record asset early (now known)
        json = _addAddressToJson(json, "Asset", asset, isFirstAddress);
        isFirstAddress = false;

        // 3. Deploy StAztec (linked to OllaCore proxy)

        stAztec = _stAztecDeployer.deploy(config, ollaCoreProxy);
        json = _addAddressToJson(json, "StAztec", stAztec, false);

        // 3.1 Deploy WithdrawalQueue (linked to OllaCore proxy)

        (withdrawalQueueImpl, withdrawalQueue) =
            _withdrawalQueueDeployer.deploy(config, ollaCoreProxy, config.governance);
        json = _addAddressToJson(json, "WithdrawalQueueImplementation", withdrawalQueueImpl, false);
        json = _addAddressToJson(json, "WithdrawalQueueProxy", withdrawalQueue, false);

        // 3.2 Deploy RewardsVault (linked to OllaCore proxy)

        (rewardsVaultImpl, rewardsVault) =
            _rewardsVaultDeployer.deploy(config, IERC20(asset), ollaCoreProxy, config.governance);
        json = _addAddressToJson(json, "RewardsVaultImplementation", rewardsVaultImpl, false);
        json = _addAddressToJson(json, "RewardsVaultProxy", rewardsVault, false);

        // Local wiring for staking stack + safety module (requires RewardsVault and core proxy)
        if (config.deployMocks) {
            // Deploy + init StakingManager + StakingProviderRegistry behind proxies
            (stakingManagerImpl, stakingManager, stakingProviderRegistryImpl, stakingProviderRegistry) =
                _mocksDeployer.deployStakingStack(config, ollaCoreProxy, rewardsVault, asset, rollupRegistry);
            json = _addAddressToJson(json, "StakingManagerImplementation", stakingManagerImpl, false);
            json = _addAddressToJson(json, "StakingManagerProxy", stakingManager, false);
            json = _addAddressToJson(json, "StakingProviderRegistryImplementation", stakingProviderRegistryImpl, false);
            json = _addAddressToJson(json, "StakingProviderRegistryProxy", stakingProviderRegistry, false);

            // Seed deterministic provider keys for local dev so staking works immediately.
            uint256 keyCount = vm.envOr("PROVIDER_KEY_COUNT", uint256(5));
            IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](keyCount);
            for (uint256 i; i < keyCount; ++i) {
                address attester = address(uint160(uint256(keccak256(abi.encodePacked("olla-attester", i)))));
                keys[i] = IStakingManager.KeyStore({
                    attester: attester,
                    publicKeyG1: G1Point({ x: 1, y: 2 }),
                    publicKeyG2: G2Point({ x0: 1, x1: 2, y0: 3, y1: 4 }),
                    proofOfPossession: G1Point({ x: 5, y: 6 })
                });
            }
            vm.startBroadcast(config.deployerPrivateKey);
            StakingProviderRegistry(stakingProviderRegistry).addKeysToProvider(keys);
            vm.stopBroadcast();

            // Configure rollup mock to bump rewards to RewardsVault on withdraw initiation
            vm.startBroadcast(config.deployerPrivateKey);
            MockAztecRollup(rollup).setRewardsCoinbase(rewardsVault);
            vm.stopBroadcast();

            json = _addAddressToJson(json, "MockAztecRollup", rollup, false);
            json = _addAddressToJson(json, "MockAztecRollupRegistry", rollupRegistry, false);

            // Local safety module stub: allows deposits/withdrawals without role setup.
            vm.startBroadcast(config.deployerPrivateKey);
            safetyModule = address(new MockSafetyModule(ollaCoreImpl));
            vm.stopBroadcast();
            _logDeployment("MockSafetyModule", safetyModule);
        }

        // Always write StakingManager to JSON once known
        json = _addAddressToJson(json, "StakingManager", stakingManager, false);

        // Safety module (required by OllaCore deposit/withdraw paths)
        json = _addAddressToJson(json, "SafetyModule", safetyModule, false);

        // 4. Initialize OllaCore with all dependencies

        config.withdrawalQueue = withdrawalQueue;
        config.rewardsVault = rewardsVault;
        config.safetyModule = safetyModule;
        _ollaCoreDeployer.initialize(config, ollaCoreProxy, asset, stAztec, stakingManager, safetyModule);

        // 5. Write deployment JSON
        json = _closeAddressesJson(json);

        // Add StAztec metadata for frontend signature generation
        string memory stAztecName = StAztec(stAztec).name();

        // Get version from EIP712 domain
        (,, string memory stAztecVersion,,,,) = IERC5267(stAztec).eip712Domain();

        json = _addMetadataToJson(json, "stAztecName", stAztecName);
        json = _addMetadataToJson(json, "stAztecVersion", stAztecVersion);

        _writeDeploymentJson(config.name, json);
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
