// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC5267 } from "@oz/interfaces/IERC5267.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { BaseDeployer } from "./base/BaseDeployer.s.sol";
import { DeployConfig } from "./config/Config.s.sol";
import { LocalConfig } from "./config/Local.s.sol";
import { TestnetConfig } from "./config/Testnet.s.sol";
import { TestnetMockedConfig } from "./config/TestnetMocked.s.sol";
import { MocksDeployer } from "./deployers/Mocks.s.sol";
import { OllaCoreDeployer } from "./deployers/OllaCore.s.sol";
import { OllaGovernanceDeployer } from "./deployers/OllaGovernance.s.sol";
import { OllaVaultDeployer } from "./deployers/OllaVault.s.sol";
import { RewardsAccumulatorDeployer } from "./deployers/RewardsAccumulator.s.sol";
import { StakingStackDeployer } from "./deployers/StakingStack.s.sol";
import { StAztecDeployer } from "./deployers/StAztec.s.sol";
import { StAztecOFTAdapterDeployer } from "./deployers/StAztecOFTAdapter.s.sol";
import { WithdrawalQueueDeployer } from "./deployers/WithdrawalQueue.s.sol";

/// @title DeployScript
/// @notice Main deployment orchestrator - deploys all contracts based on environment
contract DeployScript is BaseDeployer {
    // Deployers
    MocksDeployer internal _mocksDeployer;
    OllaCoreDeployer internal _ollaCoreDeployer;
    OllaGovernanceDeployer internal _ollaGovernanceDeployer;
    OllaVaultDeployer internal _ollaVaultDeployer;
    StAztecDeployer internal _stAztecDeployer;
    StAztecOFTAdapterDeployer internal _stAztecOFTAdapterDeployer;
    WithdrawalQueueDeployer internal _withdrawalQueueDeployer;
    RewardsAccumulatorDeployer internal _rewardsAccumulatorDeployer;
    StakingStackDeployer internal _stakingStackDeployer;

    function setUp() public {
        // Initialize deployers
        _mocksDeployer = new MocksDeployer();
        _ollaCoreDeployer = new OllaCoreDeployer();
        _ollaGovernanceDeployer = new OllaGovernanceDeployer();
        _ollaVaultDeployer = new OllaVaultDeployer();
        _stAztecDeployer = new StAztecDeployer();
        _stAztecOFTAdapterDeployer = new StAztecOFTAdapterDeployer();
        _withdrawalQueueDeployer = new WithdrawalQueueDeployer();
        _rewardsAccumulatorDeployer = new RewardsAccumulatorDeployer();
        _stakingStackDeployer = new StakingStackDeployer();
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
        address ollaGovImpl;
        address ollaGovProxy;
        address ollaCoreImpl;
        address ollaCoreProxy;
        address ollaVaultImpl;
        address ollaVaultProxy;
        address stAztec;
        address safetyModule;
        address withdrawalQueue;
        address rewardsAccumulator;
        address withdrawalQueueImpl;
        address rewardsAccumulatorImpl;
        address lzEndpoint;
        address oftAdapter;

        // Initialize deployment JSON
        string memory json = _initDeploymentJson(config.name, config.chainId, config.deployer);
        bool isFirstAddress = true;
        bool shouldRenounceDeployerRoles = config.deployer != config.governance;

        // 1. Deploy OllaGovernance (implementation + proxy + initialize)
        //    Must deploy first so it can be set as OllaCore's owner.

        (ollaGovImpl, ollaGovProxy) = _ollaGovernanceDeployer.deploy(config, config.treasury);
        json = _addAddressToJson(json, "OllaGovernanceImplementation", ollaGovImpl, isFirstAddress);
        if (isFirstAddress) isFirstAddress = false;
        json = _addAddressToJson(json, "OllaGovernanceProxy", ollaGovProxy, false);

        // 2. Deploy OllaCore (implementation + proxy)

        (ollaCoreImpl, ollaCoreProxy) = _ollaCoreDeployer.deploy(config);
        json = _addAddressToJson(json, "OllaCoreImplementation", ollaCoreImpl, false);
        json = _addAddressToJson(json, "OllaCoreProxy", ollaCoreProxy, false);

        // 3. Deploy OllaVault (implementation + proxy, uninitialized)
        //    Deployed early so the proxy address is available for StAztec and WithdrawalQueue.

        (ollaVaultImpl, ollaVaultProxy) = _ollaVaultDeployer.deploy(config);
        json = _addAddressToJson(json, "OllaVaultImplementation", ollaVaultImpl, false);
        json = _addAddressToJson(json, "OllaVaultProxy", ollaVaultProxy, false);

        // 4. Deploy or use existing external contracts (asset + rollup)
        if (config.deployMocks) {
            // Deploy local staking asset + Aztec mocks (rollup + registry)
            (asset, rollup, rollupRegistry) = _mocksDeployer.deployAssetAndRollup(config);
        } else {
            asset = config.asset;
            rollupRegistry = config.rollupRegistry;
            require(asset != address(0), "Deploy: asset address required");
            require(rollupRegistry != address(0), "Deploy: rollupRegistry address required");
        }

        // Record asset early (now known)
        json = _addAddressToJson(json, "Asset", asset, false);

        // 5. Deploy StAztec (linked to OllaVault proxy -- vault mints/burns shares)

        stAztec = _stAztecDeployer.deploy(config, ollaVaultProxy);
        json = _addAddressToJson(json, "StAztec", stAztec, false);

        // 4a. Deploy LayerZero OFTAdapter for stAztec bridging.
        //     Local: deploy a mock LZ endpoint first. Non-local: use LZ_ENDPOINT env var.
        //     The deployer is set as delegate (owner) for local dev; in production the
        //     OllaGovernance proxy would be the delegate.
        if (config.deployMocks) {
            // EID 1 = home chain for local dev
            lzEndpoint = _mocksDeployer.deployLzEndpointMock(config, 1);
            json = _addAddressToJson(json, "EndpointV2Mock", lzEndpoint, false);
        } else {
            lzEndpoint = vm.envOr("LZ_ENDPOINT", address(0));
        }

        if (lzEndpoint != address(0)) {
            address oftDelegate = config.deployMocks ? config.deployer : ollaGovProxy;
            oftAdapter = _stAztecOFTAdapterDeployer.deploy(config, stAztec, lzEndpoint, oftDelegate);
            json = _addAddressToJson(json, "StAztecOFTAdapter", oftAdapter, false);
        }
        // 5.1 Deploy WithdrawalQueue (linked to OllaVault proxy -- vault manages requests)
        //     OllaGovernance is the admin so it can manage roles and upgrades.

        (withdrawalQueueImpl, withdrawalQueue) =
            _withdrawalQueueDeployer.deploy(config, ollaVaultProxy, ollaGovProxy, 50_000);
        json = _addAddressToJson(json, "WithdrawalQueueImplementation", withdrawalQueueImpl, false);
        json = _addAddressToJson(json, "WithdrawalQueueProxy", withdrawalQueue, false);

        // 5.2 Deploy RewardsAccumulator (linked to OllaCore proxy)

        (rewardsAccumulatorImpl, rewardsAccumulator) =
            _rewardsAccumulatorDeployer.deploy(config, IERC20(asset), ollaCoreProxy, ollaGovProxy);
        json = _addAddressToJson(json, "RewardsAccumulatorImplementation", rewardsAccumulatorImpl, false);
        json = _addAddressToJson(json, "RewardsAccumulatorProxy", rewardsAccumulator, false);

        // 6. Deploy staking stack (always — StakingManager + StakingProviderRegistry behind proxies)
        (stakingManagerImpl, stakingManager, stakingProviderRegistryImpl, stakingProviderRegistry) = _stakingStackDeployer.deploy(
            config, ollaCoreProxy, rewardsAccumulator, asset, rollupRegistry, ollaGovProxy
        );
        json = _addAddressToJson(json, "StakingManagerImplementation", stakingManagerImpl, false);
        json = _addAddressToJson(json, "StakingManagerProxy", stakingManager, false);
        json = _addAddressToJson(json, "StakingProviderRegistryImplementation", stakingProviderRegistryImpl, false);
        json = _addAddressToJson(json, "StakingProviderRegistryProxy", stakingProviderRegistry, false);

        // 6a. Mock-only: seed provider keys and configure rollup mock
        if (config.deployMocks) {
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

            // Configure rollup mock to send tick() rewards to RewardsAccumulator
            vm.startBroadcast(config.deployerPrivateKey);
            MockAztecRollup(rollup).setRewardsCoinbase(rewardsAccumulator);
            vm.stopBroadcast();

            json = _addAddressToJson(json, "MockAztecRollup", rollup, false);
            json = _addAddressToJson(json, "MockAztecRollupRegistry", rollupRegistry, false);

            // Deploy real SafetyModule with generous local-dev defaults.
            // CORE must be the proxy (not impl) so onlyCore modifier works.
            vm.startBroadcast(config.deployerPrivateKey);
            safetyModule = address(
                new SafetyModule(
                    config.deployer, // admin
                    config.deployer, // guardian (deployer can pause/unpause locally)
                    ollaCoreProxy, // core -- must match OllaCore proxy address
                    ollaVaultProxy, // vault -- must match OllaVault proxy address
                    1_000_000_000e18, // depositCap -- 1B tokens, effectively unlimited
                    500, // minRateDropBps -- 5% rate drop triggers breaker
                    5_000, // maxQueueRatioBps -- 50% queue ratio triggers breaker
                    2 hours // maxAccountingDelay -- must exceed rebalanceCooldown (1h) to tolerate block-time drift
                )
            );
            vm.stopBroadcast();
            _logDeployment("SafetyModule", safetyModule);
        }

        // 7. Deploy SafetyModule (always — deployer EOA as guardian for fast emergency pause)
        vm.startBroadcast(config.deployerPrivateKey);
        safetyModule = address(
            new SafetyModule(
                ollaGovProxy, // admin (governance controls config)
                config.deployer, // guardian (deployer can pause directly, no timelock delay)
                ollaCoreProxy, // core — must match OllaCore proxy address
                ollaVaultProxy, // vault — must match OllaVault proxy address
                1_000_000_000e18, // depositCap — 1B tokens, effectively unlimited
                500, // minRateDropBps — 5% rate drop triggers breaker
                5_000, // maxQueueRatioBps — 50% queue ratio triggers breaker
                2 hours // maxAccountingDelay — must exceed rebalanceCooldown (1h) to tolerate block-time drift
            )
        );
        vm.stopBroadcast();
        _logDeployment("SafetyModule", safetyModule);

        // Always write addresses to JSON
        json = _addAddressToJson(json, "StakingManager", stakingManager, false);
        json = _addAddressToJson(json, "SafetyModule", safetyModule, false);

        // 6. Initialize OllaCore with OllaGovernance as owner
        //    OllaGovernance holds: owner(), DEFAULT_ADMIN_ROLE, GUARDIAN_ROLE

        config.withdrawalQueue = withdrawalQueue;
        config.rewardsAccumulator = rewardsAccumulator;
        config.safetyModule = safetyModule;
        // Override governance to OllaGovernance proxy (OllaCore's owner)
        config.governance = ollaGovProxy;
        _ollaCoreDeployer.initialize(config, ollaCoreProxy, asset, stAztec, stakingManager, safetyModule);

        // 8.1 Initialize OllaVault with all dependencies
        _ollaVaultDeployer.initialize(
            config, ollaVaultProxy, asset, stAztec, withdrawalQueue, ollaCoreProxy, ollaGovProxy
        );

        // 6.2 Wire OllaGovernance -> OllaCore
        _ollaGovernanceDeployer.setCore(config, ollaGovProxy, ollaCoreProxy);

        // 6.3 For local dev: wire OllaCore -> OllaVault and unpause both via governance timelock.
        //     With timelockMinDelay=0 the deployer can schedule+execute immediately.
        //     vm.warp is only needed on Anvil because Forge starts block.timestamp at 1,
        //     which collides with OZ TimelockController's _DONE_TIMESTAMP sentinel (also 1).
        if (config.timelockMinDelay == 0) {
            if (config.chainId == 31337) {
                vm.warp(block.timestamp + 1);
            }

            // setVault on OllaCore (onlyOwner -> must go through governance timelock)
            bytes memory setVaultData = abi.encodeCall(OllaCore.setVault, (ollaVaultProxy));
            vm.startBroadcast(config.deployerPrivateKey);

            OllaGovernance(payable(ollaGovProxy))
                .schedule(ollaCoreProxy, 0, setVaultData, bytes32(0), bytes32(0), config.timelockMinDelay);
            OllaGovernance(payable(ollaGovProxy)).execute(ollaCoreProxy, 0, setVaultData, bytes32(0), bytes32(0));
            vm.stopBroadcast();

            // Unpause OllaCore
            bytes memory unpauseCoreData = abi.encodeCall(OllaCore.unpause, ());
            vm.startBroadcast(config.deployerPrivateKey);
            OllaGovernance(payable(ollaGovProxy))
                .schedule(ollaCoreProxy, 0, unpauseCoreData, bytes32(0), bytes32(0), config.timelockMinDelay);
            OllaGovernance(payable(ollaGovProxy)).execute(ollaCoreProxy, 0, unpauseCoreData, bytes32(0), bytes32(0));
            vm.stopBroadcast();

            // Unpause OllaVault (GUARDIAN_ROLE granted to governance during vault init)
            bytes memory unpauseVaultData = abi.encodeCall(OllaVault.unpause, ());
            vm.startBroadcast(config.deployerPrivateKey);
            OllaGovernance(payable(ollaGovProxy))
                .schedule(ollaVaultProxy, 0, unpauseVaultData, bytes32(0), bytes32(0), config.timelockMinDelay);
            OllaGovernance(payable(ollaGovProxy)).execute(ollaVaultProxy, 0, unpauseVaultData, bytes32(0), bytes32(0));
            vm.stopBroadcast();
        }

        // 9. Renounce deployer's temporary roles on OllaGovernance.
        //    Revokes PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE and DEFAULT_ADMIN_ROLE.
        //    After this, only config.governance holds operational roles.
        if (shouldRenounceDeployerRoles) {
            _ollaGovernanceDeployer.renounceDeployerRoles(config, ollaGovProxy);
        }

        // 10. Write deployment JSON
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
        } else if (keccak256(bytes(env)) == keccak256(bytes("testnet-mocked"))) {
            TestnetMockedConfig testnetMockedConfig = new TestnetMockedConfig();
            return testnetMockedConfig.getConfig();
        } else {
            revert(string.concat("Unknown DEPLOY_ENV: ", env));
        }
    }
}
