// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { VmSafe } from "@forge-std/Vm.sol";
import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC5267 } from "@oz/interfaces/IERC5267.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { IAztecRollup } from "src/staking/interfaces/IAztecRollup.sol";
import { IAztecRollupRegistry } from "src/staking/interfaces/IAztecRollupRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { BaseDeployer } from "./base/BaseDeployer.s.sol";
import { DeployConfig } from "./config/Config.s.sol";
import { LocalConfig } from "./config/Local.s.sol";
import { MainnetConfig } from "./config/Mainnet.s.sol";
import { TestnetConfig } from "./config/Testnet.s.sol";
import { AtomicProxyFactory } from "./deployers/AtomicProxyFactory.sol";
import { MocksDeployer } from "./deployers/Mocks.s.sol";
import { OllaCoreDeployer } from "./deployers/OllaCore.s.sol";
import { OllaGovernanceDeployer } from "./deployers/OllaGovernance.s.sol";
import { OllaVaultDeployer } from "./deployers/OllaVault.s.sol";
import { RewardsAccumulatorDeployer } from "./deployers/RewardsAccumulator.s.sol";
import { StakingStackDeployer } from "./deployers/StakingStack.s.sol";
import { StAztecDeployer } from "./deployers/StAztec.s.sol";
import { StAztecOFTAdapterDeployer } from "./deployers/StAztecOFTAdapter.s.sol";
import { WithdrawalQueueDeployer } from "./deployers/WithdrawalQueue.s.sol";

interface ILayerZeroEndpointV2Delegates {
    function delegates(address oapp) external view returns (address delegate);
}

/// @title DeployScript
/// @notice Main deployment orchestrator - deploys all contracts based on environment
contract DeployScript is BaseDeployer {
    uint256 internal constant _CHAIN_LOCAL = 31337;
    uint256 internal constant _CHAIN_SEPOLIA = 11155111;
    uint256 internal constant _CHAIN_MAINNET = 1;

    bytes32 internal constant _CORE_PROXY_SALT = keccak256("olla.core.proxy.v1");
    bytes32 internal constant _VAULT_PROXY_SALT = keccak256("olla.vault.proxy.v1");

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
    bool internal _resumeEnabled;
    string internal _artifactEnv;
    AtomicProxyFactory internal _atomicProxyFactory;

    function predictCoreProxy(address implementation) external view returns (address) {
        return _predictProxyAddress(implementation, _CORE_PROXY_SALT);
    }

    function predictVaultProxy(address implementation) external view returns (address) {
        return _predictProxyAddress(implementation, _VAULT_PROXY_SALT);
    }

    function setUp() public {
        // Initialize deployers
        _mocksDeployer = new MocksDeployer();
        _ollaGovernanceDeployer = new OllaGovernanceDeployer();
        _stAztecDeployer = new StAztecDeployer();
        _stAztecOFTAdapterDeployer = new StAztecOFTAdapterDeployer();
        _withdrawalQueueDeployer = new WithdrawalQueueDeployer();
        _rewardsAccumulatorDeployer = new RewardsAccumulatorDeployer();
        _stakingStackDeployer = new StakingStackDeployer();
    }

    function run() public {
        // Load config based on ETHEREUM_CHAIN_ID
        DeployConfig memory config = _loadConfig();
        require(block.chainid == config.chainId, "Deploy: ETHEREUM_CHAIN_ID/RPC chain mismatch");

        _validateAddressSeparation(config);
        _enforceOperatorFlowGuardrails(config);

        _resetLocalArtifactIfStale(config);

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

        _resumeEnabled = _shouldEnableResume(config);
        _artifactEnv = config.name;
        if (_resumeEnabled) {
            _ensureDeploymentArtifact(
                _artifactEnv,
                config.chainId,
                config.deployer,
                config.deployMocks,
                config.asset,
                config.rollupRegistry,
                config.lzEndpoint
            );
        }
        _atomicProxyFactory = _resolveOrDeployAtomicProxyFactory(config);
        _ollaCoreDeployer = new OllaCoreDeployer(_atomicProxyFactory);
        _ollaVaultDeployer = new OllaVaultDeployer(_atomicProxyFactory);

        address configuredGovernance = config.governance;
        // Keep deployer roles when explicitly using mock flows with governance == deployer.
        // This avoids orphaning timelock operational roles on strict mock deployments.
        bool shouldRenounceDeployerRoles = config.deployer != configuredGovernance;
        _setPhase("A", false);

        // 1. Deploy OllaGovernance (implementation + proxy + initialize)
        //    Must deploy first so it can be set as OllaCore's owner.

        (ollaGovImpl, ollaGovProxy) = _resolveOrDeployOllaGovernance(config);

        // 2. Deploy OllaCore and OllaVault implementations.
        //    Proxies are deployed after all dependencies are ready.
        (ollaCoreImpl, ollaCoreProxy) = _resolveOrDeployOllaCoreImplementation(config);
        (ollaVaultImpl, ollaVaultProxy) = _resolveOrDeployOllaVaultImplementation(config);

        // 4. Deploy or use existing external contracts (asset + rollup)
        if (config.deployMocks) {
            (asset, rollup, rollupRegistry) = _resolveOrDeployMocks(config);
        } else {
            asset = config.asset;
            rollupRegistry = config.rollupRegistry;
            require(asset != address(0), "Deploy: asset address required");
            require(rollupRegistry != address(0), "Deploy: rollupRegistry address required");
            _validateRealAztecDependencies(asset, rollupRegistry);

            address existingAsset = _readAddress("Asset");
            if (existingAsset != address(0)) {
                require(existingAsset == asset, "Deploy: ADDRESS_STATE_MISMATCH.Asset");
            } else {
                _recordAddress("Asset", asset);
            }
        }

        address predictedCoreProxy = _predictProxyAddress(ollaCoreImpl, _CORE_PROXY_SALT);
        address predictedVaultProxy = _predictProxyAddress(ollaVaultImpl, _VAULT_PROXY_SALT);

        // 5. Deploy StAztec (linked to predicted OllaVault proxy -- vault mints/burns shares)
        stAztec = _resolveOrDeployStAztec(config, predictedVaultProxy);

        // 4a. Deploy LayerZero OFTAdapter for stAztec bridging.
        //     Local: deploy a mock LZ endpoint first. Non-local: use LZ_ENDPOINT env var.
        //     The deployer is set as delegate (owner) for local dev; in production the
        //     OllaGovernance proxy would be the delegate.
        if (config.deployMocks && !config.lzEndpointDefined) {
            // EID 1 = home chain for local dev
            lzEndpoint = _resolveOrDeployLzEndpointMock(config);
        } else {
            lzEndpoint = config.lzEndpoint;
        }

        if (lzEndpoint != address(0)) {
            address oftDelegate = config.deployMocks ? config.deployer : ollaGovProxy;
            oftAdapter = _resolveOrDeployOftAdapter(config, stAztec, lzEndpoint, oftDelegate);
        }
        // 5.1 Deploy WithdrawalQueue (linked to OllaVault proxy -- vault manages requests)
        //     OllaGovernance is the admin so it can manage roles and upgrades.

        (withdrawalQueueImpl, withdrawalQueue) =
            _resolveOrDeployWithdrawalQueue(config, predictedVaultProxy, ollaGovProxy);

        // 5.2 Deploy RewardsAccumulator (linked to OllaCore proxy)

        (rewardsAccumulatorImpl, rewardsAccumulator) =
            _resolveOrDeployRewardsAccumulator(config, asset, predictedCoreProxy, ollaGovProxy);

        // 6. Deploy staking stack (always — StakingManager + StakingProviderRegistry behind proxies)
        (stakingManagerImpl, stakingManager, stakingProviderRegistryImpl, stakingProviderRegistry) = _resolveOrDeployStakingStack(
            config, predictedCoreProxy, rewardsAccumulator, asset, rollupRegistry, ollaGovProxy
        );

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
            (bool keysSeeded, bool hasKeysFlag) = _readFlag("mockProviderKeysSeeded");
            if (!hasKeysFlag || !keysSeeded) {
                vm.startBroadcast(config.deployerPrivateKey);
                StakingProviderRegistry(stakingProviderRegistry).addKeysToProvider(keys);
                vm.stopBroadcast();
                _recordFlag("mockProviderKeysSeeded", true);
            }

            // Configure rollup mock to send tick() rewards to RewardsAccumulator
            if (MockAztecRollup(rollup).rewardsCoinbase() != rewardsAccumulator) {
                vm.startBroadcast(config.deployerPrivateKey);
                MockAztecRollup(rollup).setRewardsCoinbase(rewardsAccumulator);
                vm.stopBroadcast();
            }
        }

        // 7. Deploy SafetyModule (always — deployer EOA as guardian for fast emergency pause)
        safetyModule = _resolveOrDeploySafetyModule(config, ollaGovProxy, predictedCoreProxy, predictedVaultProxy);

        _recordAddress("StakingManager", stakingManager);
        _recordAddress("SafetyModule", safetyModule);

        // 7.5 Deploy core/vault proxies and initialize atomically in same transaction.
        config.withdrawalQueue = withdrawalQueue;
        config.rewardsAccumulator = rewardsAccumulator;
        config.safetyModule = safetyModule;
        config.governance = ollaGovProxy;
        ollaCoreProxy = _resolveOrDeployOllaCoreProxy(
            config, ollaCoreImpl, asset, stAztec, stakingManager, safetyModule, _CORE_PROXY_SALT
        );
        ollaVaultProxy = _resolveOrDeployOllaVaultProxy(
            config, ollaVaultImpl, asset, stAztec, withdrawalQueue, ollaCoreProxy, ollaGovProxy, _VAULT_PROXY_SALT
        );

        require(ollaCoreProxy == predictedCoreProxy, "Deploy: ADDRESS_STATE_MISMATCH.OllaCoreProxy.predicted");
        require(ollaVaultProxy == predictedVaultProxy, "Deploy: ADDRESS_STATE_MISMATCH.OllaVaultProxy.predicted");

        _setPhase("B", false);

        // 6.2 Wire OllaGovernance -> OllaCore
        _setGovernanceCoreIfNeeded(config, ollaGovProxy, ollaCoreProxy);

        _setPhase("C", false);

        // 6.3 For non-strict chains: wire OllaCore -> OllaVault and unpause via governance timelock.
        //     With timelockMinDelay=0 the deployer can schedule+execute immediately.
        //     vm.warp is only needed on Anvil because Forge starts block.timestamp at 1,
        //     which collides with OZ TimelockController's _DONE_TIMESTAMP sentinel (also 1).
        if (config.timelockMinDelay == 0 && !_isStrictChain(config.chainId)) {
            if (config.chainId == 31337) {
                vm.warp(block.timestamp + 1);
            }

            // setVault on OllaCore (onlyOwner -> must go through governance timelock)
            if (OllaCore(ollaCoreProxy).vault() != ollaVaultProxy) {
                bytes memory setVaultData = abi.encodeCall(OllaCore.setVault, (ollaVaultProxy));
                vm.startBroadcast(config.deployerPrivateKey);
                OllaGovernance(payable(ollaGovProxy))
                    .schedule(ollaCoreProxy, 0, setVaultData, bytes32(0), bytes32(0), config.timelockMinDelay);
                OllaGovernance(payable(ollaGovProxy)).execute(ollaCoreProxy, 0, setVaultData, bytes32(0), bytes32(0));
                vm.stopBroadcast();
            }

            // Unpause OllaCore
            if (OllaCore(ollaCoreProxy).paused()) {
                bytes memory unpauseCoreData = abi.encodeCall(OllaCore.unpause, ());
                vm.startBroadcast(config.deployerPrivateKey);
                OllaGovernance(payable(ollaGovProxy))
                    .schedule(ollaCoreProxy, 0, unpauseCoreData, bytes32(0), bytes32(0), config.timelockMinDelay);
                OllaGovernance(payable(ollaGovProxy)).execute(ollaCoreProxy, 0, unpauseCoreData, bytes32(0), bytes32(0));
                vm.stopBroadcast();
            }

            // Unpause OllaVault (GUARDIAN_ROLE granted to governance during vault init)
            if (OllaVault(ollaVaultProxy).paused()) {
                bytes memory unpauseVaultData = abi.encodeCall(OllaVault.unpause, ());
                vm.startBroadcast(config.deployerPrivateKey);
                OllaGovernance(payable(ollaGovProxy))
                    .schedule(ollaVaultProxy, 0, unpauseVaultData, bytes32(0), bytes32(0), config.timelockMinDelay);
                OllaGovernance(payable(ollaGovProxy))
                    .execute(ollaVaultProxy, 0, unpauseVaultData, bytes32(0), bytes32(0));
                vm.stopBroadcast();
            }
        } else {
            _logInfo("Activation via governance ops required: OllaCore.setVault(OllaVault) + unpause steps");
        }

        // 9. Renounce deployer's temporary roles on OllaGovernance.
        //    Revokes PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE and DEFAULT_ADMIN_ROLE.
        //    After this, only config.governance holds operational roles.
        if (shouldRenounceDeployerRoles) {
            _requireSafeGovernanceRoleHandover(ollaGovProxy, config.deployer, configuredGovernance);
            if (
                AccessControlUpgradeable(ollaGovProxy)
                        .hasRole(OllaGovernance(payable(ollaGovProxy)).PROPOSER_ROLE(), config.deployer)
                    || AccessControlUpgradeable(ollaGovProxy)
                        .hasRole(OllaGovernance(payable(ollaGovProxy)).EXECUTOR_ROLE(), config.deployer)
                    || AccessControlUpgradeable(ollaGovProxy)
                        .hasRole(OllaGovernance(payable(ollaGovProxy)).CANCELLER_ROLE(), config.deployer)
                    || AccessControlUpgradeable(ollaGovProxy)
                        .hasRole(OllaGovernance(payable(ollaGovProxy)).DEFAULT_ADMIN_ROLE(), config.deployer)
            ) {
                _ollaGovernanceDeployer.renounceDeployerRoles(config, ollaGovProxy);
            }
        }

        _assertGovernanceOperationalRoles(ollaGovProxy, config.deployer, configuredGovernance);

        _validateDeploymentState(
            config,
            asset,
            rollupRegistry,
            ollaGovProxy,
            ollaCoreProxy,
            ollaVaultProxy,
            stakingManager,
            stakingProviderRegistry,
            withdrawalQueue,
            rewardsAccumulator,
            safetyModule
        );

        // Add StAztec metadata for frontend signature generation
        string memory stAztecName = StAztec(stAztec).name();

        // Get version from EIP712 domain
        (,, string memory stAztecVersion,,,,) = IERC5267(stAztec).eip712Domain();

        _recordMetadataString("stAztecName", stAztecName);
        _recordMetadataString("stAztecVersion", stAztecVersion);
        _setPhase("D", true);
    }

    function _resolveOrDeployOllaGovernance(DeployConfig memory config)
        internal
        returns (address implementation, address proxy)
    {
        implementation = _readAddress("OllaGovernanceImplementation");
        proxy = _readAddress("OllaGovernanceProxy");

        if ((implementation != address(0) && !_hasCode(implementation)) || (proxy != address(0) && !_hasCode(proxy))) {
            if (_shouldFailFastOnMissingResumeCode(config)) {
                _requireCode(implementation, "OllaGovernanceImplementation");
                _requireCode(proxy, "OllaGovernanceProxy");
            }
            implementation = address(0);
            proxy = address(0);
        }

        if (implementation != address(0) || proxy != address(0)) {
            require(
                implementation != address(0) && proxy != address(0),
                "Deploy: MISSING_REQUIRED_PREVIOUS_PHASE_OUTPUT.OllaGovernance"
            );
            return (implementation, proxy);
        }

        (implementation, proxy) = _ollaGovernanceDeployer.deploy(config, config.treasury);
        _recordAddress("OllaGovernanceImplementation", implementation);
        _recordAddress("OllaGovernanceProxy", proxy);
    }

    function _resolveOrDeployAtomicProxyFactory(DeployConfig memory config)
        internal
        returns (AtomicProxyFactory factory)
    {
        address existing = _readAddress("AtomicProxyFactory");
        if (existing != address(0)) {
            if (!_hasCode(existing)) {
                if (_shouldFailFastOnMissingResumeCode(config)) {
                    _requireCode(existing, "AtomicProxyFactory");
                }
            } else {
                factory = AtomicProxyFactory(existing);
                try factory.DEPLOYER() returns (address existingDeployer) {
                    require(
                        existingDeployer == config.deployer,
                        "Deploy: ADDRESS_STATE_MISMATCH.AtomicProxyFactory.deployer"
                    );
                    return factory;
                } catch {
                    if (_shouldFailFastOnMissingResumeCode(config)) {
                        revert("Deploy: ADDRESS_STATE_MISMATCH.AtomicProxyFactory.interface");
                    }
                }
            }
        }

        vm.startBroadcast(config.deployerPrivateKey);
        factory = new AtomicProxyFactory(config.deployer);
        vm.stopBroadcast();
        _recordAddress("AtomicProxyFactory", address(factory));
    }

    function _resolveOrDeployOllaCoreImplementation(DeployConfig memory config)
        internal
        returns (address implementation, address proxy)
    {
        implementation = _readAddress("OllaCoreImplementation");
        proxy = _readAddress("OllaCoreProxy");

        if ((implementation != address(0) && !_hasCode(implementation)) || (proxy != address(0) && !_hasCode(proxy))) {
            if (_shouldFailFastOnMissingResumeCode(config)) {
                _requireCode(implementation, "OllaCoreImplementation");
                _requireCode(proxy, "OllaCoreProxy");
            }
            implementation = address(0);
            proxy = address(0);
        }

        if (implementation != address(0)) {
            return (implementation, proxy);
        }

        if (proxy != address(0)) {
            revert("Deploy: MISSING_REQUIRED_PREVIOUS_PHASE_OUTPUT.OllaCoreImplementation");
        }

        vm.startBroadcast(config.deployerPrivateKey);
        OllaCore coreImpl = new OllaCore();
        vm.stopBroadcast();
        implementation = address(coreImpl);

        _recordAddress("OllaCoreImplementation", implementation);
    }

    function _resolveOrDeployOllaVaultImplementation(DeployConfig memory config)
        internal
        returns (address implementation, address proxy)
    {
        implementation = _readAddress("OllaVaultImplementation");
        proxy = _readAddress("OllaVaultProxy");

        if ((implementation != address(0) && !_hasCode(implementation)) || (proxy != address(0) && !_hasCode(proxy))) {
            if (_shouldFailFastOnMissingResumeCode(config)) {
                _requireCode(implementation, "OllaVaultImplementation");
                _requireCode(proxy, "OllaVaultProxy");
            }
            implementation = address(0);
            proxy = address(0);
        }

        if (implementation != address(0)) {
            return (implementation, proxy);
        }

        if (proxy != address(0)) {
            revert("Deploy: MISSING_REQUIRED_PREVIOUS_PHASE_OUTPUT.OllaVaultImplementation");
        }

        vm.startBroadcast(config.deployerPrivateKey);
        OllaVault vaultImpl = new OllaVault();
        vm.stopBroadcast();
        implementation = address(vaultImpl);

        _recordAddress("OllaVaultImplementation", implementation);
    }

    function _resolveOrDeployOllaCoreProxy(
        DeployConfig memory config,
        address implementation,
        address asset,
        address stAztec,
        address stakingManager,
        address safetyModule,
        bytes32 salt
    ) internal returns (address proxy) {
        proxy = _readAddress("OllaCoreProxy");

        if (proxy != address(0)) {
            _requireCode(proxy, "OllaCoreProxy");
            require(proxy == _predictProxyAddress(implementation, salt), "Deploy: ADDRESS_STATE_MISMATCH.OllaCoreProxy");
            _assertCoreInitialized(
                proxy, asset, stAztec, stakingManager, config.rewardsAccumulator, safetyModule, config.governance
            );
            _recordFlag("coreInitialized", true);
            return proxy;
        }

        (/*implementation*/, proxy) =
            _ollaCoreDeployer.deploy(config, implementation, asset, stAztec, stakingManager, safetyModule, salt);
        require(proxy == _predictProxyAddress(implementation, salt), "Deploy: ADDRESS_STATE_MISMATCH.OllaCoreProxy");
        _recordAddress("OllaCoreProxy", proxy);
        _recordFlag("coreInitialized", true);
    }

    function _resolveOrDeployOllaVaultProxy(
        DeployConfig memory config,
        address implementation,
        address asset,
        address stAztec,
        address withdrawalQueue,
        address core,
        address governance,
        bytes32 salt
    ) internal returns (address proxy) {
        proxy = _readAddress("OllaVaultProxy");

        if (proxy != address(0)) {
            _requireCode(proxy, "OllaVaultProxy");
            require(
                proxy == _predictProxyAddress(implementation, salt), "Deploy: ADDRESS_STATE_MISMATCH.OllaVaultProxy"
            );
            _assertVaultInitialized(proxy, asset, withdrawalQueue, core, governance);
            _recordFlag("vaultInitialized", true);
            return proxy;
        }

        (/*implementation*/, proxy) = _ollaVaultDeployer.deploy(
            config, implementation, asset, stAztec, withdrawalQueue, core, governance, salt
        );
        require(proxy == _predictProxyAddress(implementation, salt), "Deploy: ADDRESS_STATE_MISMATCH.OllaVaultProxy");
        _recordAddress("OllaVaultProxy", proxy);
        _recordFlag("vaultInitialized", true);
    }

    function _resolveOrDeployMocks(DeployConfig memory config)
        internal
        returns (address asset, address rollup, address rollupRegistry)
    {
        asset = _readAddress("Asset");
        rollup = _readAddress("MockAztecRollup");
        rollupRegistry = _readAddress("MockAztecRollupRegistry");

        if (
            (asset != address(0) && !_hasCode(asset)) || (rollup != address(0) && !_hasCode(rollup))
                || (rollupRegistry != address(0) && !_hasCode(rollupRegistry))
        ) {
            if (_shouldFailFastOnMissingResumeCode(config)) {
                _requireCode(asset, "Asset");
                _requireCode(rollup, "MockAztecRollup");
                _requireCode(rollupRegistry, "MockAztecRollupRegistry");
            }
            asset = address(0);
            rollup = address(0);
            rollupRegistry = address(0);
        }

        if (asset != address(0) || rollup != address(0) || rollupRegistry != address(0)) {
            require(
                asset != address(0) && rollup != address(0) && rollupRegistry != address(0),
                "Deploy: MISSING_REQUIRED_PREVIOUS_PHASE_OUTPUT.MockAztec"
            );
            return (asset, rollup, rollupRegistry);
        }

        (asset, rollup, rollupRegistry) = _mocksDeployer.deployAssetAndRollup(config);
        _recordAddress("Asset", asset);
        _recordAddress("MockAztecRollup", rollup);
        _recordAddress("MockAztecRollupRegistry", rollupRegistry);
    }

    function _resolveOrDeployStAztec(DeployConfig memory config, address vaultProxy)
        internal
        returns (address stAztec)
    {
        stAztec = _readAddress("StAztec");
        if (stAztec != address(0)) {
            if (!_hasCode(stAztec)) {
                if (_shouldFailFastOnMissingResumeCode(config)) {
                    _requireCode(stAztec, "StAztec");
                }
            } else {
                bool matchesVault;
                try StAztec(stAztec).OLLA_VAULT() returns (address configuredVault) {
                    matchesVault = configuredVault == vaultProxy;
                } catch {
                    matchesVault = false;
                }

                if (matchesVault) {
                    return stAztec;
                }

                if (_shouldFailFastOnMissingResumeCode(config)) {
                    revert("Deploy: ADDRESS_STATE_MISMATCH.StAztec.OLLA_VAULT");
                }
            }
        }

        stAztec = _stAztecDeployer.deploy(config, vaultProxy);
        _recordAddress("StAztec", stAztec);
    }

    function _resolveOrDeployLzEndpointMock(DeployConfig memory config) internal returns (address endpoint) {
        endpoint = _readAddress("EndpointV2Mock");
        if (endpoint != address(0) && _hasCode(endpoint)) {
            return endpoint;
        }

        endpoint = _mocksDeployer.deployLzEndpointMock(config, 1);
        _recordAddress("EndpointV2Mock", endpoint);
    }

    function _resolveOrDeployOftAdapter(
        DeployConfig memory config,
        address stAztec,
        address lzEndpoint,
        address delegate
    ) internal returns (address adapter) {
        adapter = _readAddress("StAztecOFTAdapter");
        if (adapter != address(0)) {
            if (!_hasCode(adapter)) {
                if (_shouldFailFastOnMissingResumeCode(config)) {
                    _requireCode(adapter, "StAztecOFTAdapter");
                }
            } else {
                if (_matchesOftAdapter(adapter, stAztec, lzEndpoint, delegate)) {
                    return adapter;
                }

                if (_shouldFailFastOnMissingResumeCode(config)) {
                    revert("Deploy: ADDRESS_STATE_MISMATCH.StAztecOFTAdapter");
                }
            }
        }

        adapter = _stAztecOFTAdapterDeployer.deploy(config, stAztec, lzEndpoint, delegate);
        _recordAddress("StAztecOFTAdapter", adapter);
    }

    function _resolveOrDeployRewardsAccumulator(DeployConfig memory config, address asset, address core, address admin)
        internal
        returns (address implementation, address proxy)
    {
        implementation = _readAddress("RewardsAccumulatorImplementation");
        proxy = _readAddress("RewardsAccumulatorProxy");

        if ((implementation != address(0) && !_hasCode(implementation)) || (proxy != address(0) && !_hasCode(proxy))) {
            if (_shouldFailFastOnMissingResumeCode(config)) {
                _requireCode(implementation, "RewardsAccumulatorImplementation");
                _requireCode(proxy, "RewardsAccumulatorProxy");
            }
            implementation = address(0);
            proxy = address(0);
        }

        if (implementation != address(0) || proxy != address(0)) {
            require(
                implementation != address(0) && proxy != address(0),
                "Deploy: MISSING_REQUIRED_PREVIOUS_PHASE_OUTPUT.RewardsAccumulator"
            );
            require(IRewardsAccumulator(proxy).core() == core, "Deploy: ADDRESS_STATE_MISMATCH.RewardsAccumulator.core");
            require(
                AccessControlUpgradeable(proxy).hasRole(bytes32(0), admin),
                "Deploy: ADDRESS_STATE_MISMATCH.RewardsAccumulator.admin"
            );
            return (implementation, proxy);
        }

        (implementation, proxy) = _rewardsAccumulatorDeployer.deploy(config, IERC20(asset), core, admin);
        _recordAddress("RewardsAccumulatorImplementation", implementation);
        _recordAddress("RewardsAccumulatorProxy", proxy);
    }

    function _resolveOrDeployWithdrawalQueue(DeployConfig memory config, address vaultProxy, address admin)
        internal
        returns (address implementation, address proxy)
    {
        implementation = _readAddress("WithdrawalQueueImplementation");
        proxy = _readAddress("WithdrawalQueueProxy");

        if ((implementation != address(0) && !_hasCode(implementation)) || (proxy != address(0) && !_hasCode(proxy))) {
            if (_shouldFailFastOnMissingResumeCode(config)) {
                _requireCode(implementation, "WithdrawalQueueImplementation");
                _requireCode(proxy, "WithdrawalQueueProxy");
            }
            implementation = address(0);
            proxy = address(0);
        }

        if (implementation != address(0) || proxy != address(0)) {
            require(
                implementation != address(0) && proxy != address(0),
                "Deploy: MISSING_REQUIRED_PREVIOUS_PHASE_OUTPUT.WithdrawalQueue"
            );
            require(
                WithdrawalQueue(proxy).vault() == vaultProxy, "Deploy: ADDRESS_STATE_MISMATCH.WithdrawalQueue.vault"
            );
            require(
                AccessControlUpgradeable(proxy).hasRole(bytes32(0), admin),
                "Deploy: ADDRESS_STATE_MISMATCH.WithdrawalQueue.admin"
            );
            return (implementation, proxy);
        }

        (implementation, proxy) = _withdrawalQueueDeployer.deploy(config, vaultProxy, admin, 50_000);
        _recordAddress("WithdrawalQueueImplementation", implementation);
        _recordAddress("WithdrawalQueueProxy", proxy);
    }

    function _resolveOrDeployStakingStack(
        DeployConfig memory config,
        address core,
        address rewardsAccumulator,
        address asset,
        address rollupRegistry,
        address governanceAdmin
    )
        internal
        returns (
            address stakingManagerImpl,
            address stakingManagerProxy,
            address stakingProviderRegistryImpl,
            address stakingProviderRegistryProxy
        )
    {
        stakingManagerImpl = _readAddress("StakingManagerImplementation");
        stakingManagerProxy = _readAddress("StakingManagerProxy");
        stakingProviderRegistryImpl = _readAddress("StakingProviderRegistryImplementation");
        stakingProviderRegistryProxy = _readAddress("StakingProviderRegistryProxy");

        if (
            (stakingManagerImpl != address(0) && !_hasCode(stakingManagerImpl))
                || (stakingManagerProxy != address(0) && !_hasCode(stakingManagerProxy))
                || (stakingProviderRegistryImpl != address(0) && !_hasCode(stakingProviderRegistryImpl))
                || (stakingProviderRegistryProxy != address(0) && !_hasCode(stakingProviderRegistryProxy))
        ) {
            if (_shouldFailFastOnMissingResumeCode(config)) {
                _requireCode(stakingManagerImpl, "StakingManagerImplementation");
                _requireCode(stakingManagerProxy, "StakingManagerProxy");
                _requireCode(stakingProviderRegistryImpl, "StakingProviderRegistryImplementation");
                _requireCode(stakingProviderRegistryProxy, "StakingProviderRegistryProxy");
            }
            stakingManagerImpl = address(0);
            stakingManagerProxy = address(0);
            stakingProviderRegistryImpl = address(0);
            stakingProviderRegistryProxy = address(0);
        }

        if (
            stakingManagerImpl != address(0) || stakingManagerProxy != address(0)
                || stakingProviderRegistryImpl != address(0) || stakingProviderRegistryProxy != address(0)
        ) {
            require(
                stakingManagerImpl != address(0) && stakingManagerProxy != address(0)
                    && stakingProviderRegistryImpl != address(0) && stakingProviderRegistryProxy != address(0),
                "Deploy: MISSING_REQUIRED_PREVIOUS_PHASE_OUTPUT.StakingStack"
            );

            require(
                StakingManager(stakingManagerProxy).core() == core, "Deploy: ADDRESS_STATE_MISMATCH.StakingManager.core"
            );
            require(
                StakingManager(stakingManagerProxy).rewardsAccumulator() == rewardsAccumulator,
                "Deploy: ADDRESS_STATE_MISMATCH.StakingManager.rewardsAccumulator"
            );
            require(
                address(StakingManager(stakingManagerProxy).stakingAsset()) == asset,
                "Deploy: ADDRESS_STATE_MISMATCH.StakingManager.asset"
            );
            require(
                address(StakingManager(stakingManagerProxy).rollupRegistry()) == rollupRegistry,
                "Deploy: ADDRESS_STATE_MISMATCH.StakingManager.rollupRegistry"
            );
            require(
                address(StakingManager(stakingManagerProxy).stakingProviderRegistry()) == stakingProviderRegistryProxy,
                "Deploy: ADDRESS_STATE_MISMATCH.StakingManager.providerRegistry"
            );
            require(
                StakingProviderRegistry(stakingProviderRegistryProxy).stakingManager() == stakingManagerProxy,
                "Deploy: ADDRESS_STATE_MISMATCH.StakingProviderRegistry.stakingManager"
            );
            require(
                AccessControlUpgradeable(stakingManagerProxy).hasRole(bytes32(0), governanceAdmin),
                "Deploy: ADDRESS_STATE_MISMATCH.StakingManager.admin"
            );
            require(
                AccessControlUpgradeable(stakingProviderRegistryProxy).hasRole(bytes32(0), governanceAdmin),
                "Deploy: ADDRESS_STATE_MISMATCH.StakingProviderRegistry.admin"
            );
            return (stakingManagerImpl, stakingManagerProxy, stakingProviderRegistryImpl, stakingProviderRegistryProxy);
        }

        (stakingManagerImpl, stakingManagerProxy, stakingProviderRegistryImpl, stakingProviderRegistryProxy) =
            _stakingStackDeployer.deploy(config, core, rewardsAccumulator, asset, rollupRegistry, governanceAdmin);
        _recordAddress("StakingManagerImplementation", stakingManagerImpl);
        _recordAddress("StakingManagerProxy", stakingManagerProxy);
        _recordAddress("StakingProviderRegistryImplementation", stakingProviderRegistryImpl);
        _recordAddress("StakingProviderRegistryProxy", stakingProviderRegistryProxy);
    }

    function _resolveOrDeploySafetyModule(DeployConfig memory config, address admin, address core, address vault)
        internal
        returns (address safetyModule)
    {
        safetyModule = _readAddress("SafetyModule");
        if (safetyModule != address(0) && _hasCode(safetyModule)) {
            require(SafetyModule(safetyModule).CORE() == core, "Deploy: ADDRESS_STATE_MISMATCH.SafetyModule.core");
            require(SafetyModule(safetyModule).VAULT() == vault, "Deploy: ADDRESS_STATE_MISMATCH.SafetyModule.vault");
            require(
                AccessControlUpgradeable(safetyModule).hasRole(bytes32(0), admin),
                "Deploy: ADDRESS_STATE_MISMATCH.SafetyModule.admin"
            );
            return safetyModule;
        }

        vm.startBroadcast(config.deployerPrivateKey);
        safetyModule =
            address(new SafetyModule(admin, config.guardian, core, vault, 1_000_000_000e18, 500, 5_000, 2 hours));
        vm.stopBroadcast();
        _logDeployment("SafetyModule", safetyModule);
        _recordAddress("SafetyModule", safetyModule);
    }

    function _setGovernanceCoreIfNeeded(DeployConfig memory config, address governance, address core) internal {
        if (OllaGovernance(payable(governance)).core() == core) {
            return;
        }
        require(
            OllaGovernance(payable(governance)).core() == address(0), "Deploy: ADDRESS_STATE_MISMATCH.Governance.core"
        );
        _ollaGovernanceDeployer.setCore(config, governance, core);
        require(
            OllaGovernance(payable(governance)).core() == core, "Deploy: ADDRESS_STATE_MISMATCH.Governance.core.after"
        );
    }

    function _resetLocalArtifactIfStale(DeployConfig memory config) internal {
        if (config.chainId != _CHAIN_LOCAL) return;
        if (!_deploymentExists(config.name)) return;

        if (_isStaleLocalDeployment(config)) {
            _logInfo("Local artifact has stale addresses; resetting deployment file");
            vm.removeFile(_getDeploymentPath(config.name));
        }
    }

    /// @notice Load config based on ETHEREUM_CHAIN_ID.
    function _loadConfig() internal returns (DeployConfig memory) {
        uint256 chainId = vm.envUint("ETHEREUM_CHAIN_ID");

        if (chainId == _CHAIN_LOCAL) {
            LocalConfig localConfig = new LocalConfig();
            return localConfig.getConfig();
        } else if (chainId == _CHAIN_SEPOLIA) {
            TestnetConfig testnetConfig = new TestnetConfig();
            return testnetConfig.getConfig();
        } else if (chainId == _CHAIN_MAINNET) {
            MainnetConfig mainnetConfig = new MainnetConfig();
            return mainnetConfig.getConfig();
        } else {
            revert("Deploy: unsupported ETHEREUM_CHAIN_ID");
        }
    }

    function _recordAddress(string memory key, address value) internal {
        if (!_resumeEnabled) {
            return;
        }
        _setDeploymentAddress(_artifactEnv, key, value);
    }

    function _recordMetadataString(string memory key, string memory value) internal {
        if (!_resumeEnabled) {
            return;
        }
        _setDeploymentMetadataString(_artifactEnv, key, value);
    }

    function _setPhase(string memory phase, bool completed) internal {
        if (!_resumeEnabled) {
            return;
        }
        _setDeploymentPhase(_artifactEnv, phase, completed);
    }

    function _recordFlag(string memory key, bool value) internal {
        if (!_resumeEnabled) {
            return;
        }
        _setDeploymentFlag(_artifactEnv, key, value);
    }

    function _matchesOftAdapter(address adapter, address stAztec, address lzEndpoint, address delegate)
        internal
        view
        returns (bool)
    {
        (bool okToken, address token) = _staticcallAddress(adapter, abi.encodeWithSignature("token()"));
        if (!okToken || token != stAztec) return false;

        (bool okEndpoint, address endpoint) = _staticcallAddress(adapter, abi.encodeWithSignature("endpoint()"));
        if (!okEndpoint || endpoint != lzEndpoint) return false;

        (bool okOwner, address ownerAddr) = _staticcallAddress(adapter, abi.encodeWithSignature("owner()"));
        if (!okOwner || ownerAddr != delegate) return false;

        try ILayerZeroEndpointV2Delegates(lzEndpoint).delegates(adapter) returns (address endpointDelegate) {
            return endpointDelegate == delegate;
        } catch {
            return false;
        }
    }

    function _staticcallAddress(address target, bytes memory data) internal view returns (bool ok, address decoded) {
        bytes memory returnData;
        (ok, returnData) = target.staticcall(data);
        if (!ok || returnData.length < 32) {
            return (false, address(0));
        }
        decoded = abi.decode(returnData, (address));
    }

    function _assertCoreInitialized(
        address core,
        address asset,
        address stAztec,
        address stakingManager,
        address rewardsAccumulator,
        address safetyModule,
        address governance
    ) internal view {
        require(OllaCore(core).owner() == governance, "Deploy: ADDRESS_STATE_MISMATCH.OllaCore.owner");
        require(OllaCore(core).asset() == asset, "Deploy: ADDRESS_STATE_MISMATCH.OllaCore.asset");
        require(OllaCore(core).stAztec() == stAztec, "Deploy: ADDRESS_STATE_MISMATCH.OllaCore.stAztec");
        require(
            OllaCore(core).stakingManager() == stakingManager, "Deploy: ADDRESS_STATE_MISMATCH.OllaCore.stakingManager"
        );
        require(
            OllaCore(core).rewardsAccumulator() == rewardsAccumulator,
            "Deploy: ADDRESS_STATE_MISMATCH.OllaCore.rewardsAccumulator"
        );
        require(OllaCore(core).safetyModule() == safetyModule, "Deploy: ADDRESS_STATE_MISMATCH.OllaCore.safetyModule");
        require(
            AccessControlUpgradeable(core).hasRole(bytes32(0), governance),
            "Deploy: ADDRESS_STATE_MISMATCH.OllaCore.admin"
        );
    }

    function _assertVaultInitialized(
        address vault,
        address asset,
        address withdrawalQueue,
        address core,
        address governance
    ) internal view {
        require(OllaVault(vault).owner() == governance, "Deploy: ADDRESS_STATE_MISMATCH.OllaVault.owner");
        require(OllaVault(vault).asset() == asset, "Deploy: ADDRESS_STATE_MISMATCH.OllaVault.asset");
        require(OllaVault(vault).core() == core, "Deploy: ADDRESS_STATE_MISMATCH.OllaVault.core");
        require(
            OllaVault(vault).withdrawalQueue() == withdrawalQueue,
            "Deploy: ADDRESS_STATE_MISMATCH.OllaVault.withdrawalQueue"
        );
        require(
            AccessControlUpgradeable(vault).hasRole(bytes32(0), governance),
            "Deploy: ADDRESS_STATE_MISMATCH.OllaVault.admin"
        );
    }

    function _requireCode(address addr, string memory label) internal view {
        if (addr == address(0)) {
            return;
        }
        require(
            addr.code.length > 0,
            string.concat("Deploy: ADDRESS_REUSED_BUT_NO_CODE.", label, ".", _addressToString(addr))
        );
    }

    function _hasCode(address addr) internal view returns (bool) {
        return addr.code.length > 0;
    }

    function _shouldEnableResume(DeployConfig memory config) internal view returns (bool) {
        if (vm.envOr("DEPLOY_RESUME", false)) {
            return true;
        }
        if (config.chainId == _CHAIN_LOCAL) {
            return true;
        }
        string memory step = vm.envOr("DEPLOY_STEP", string(""));
        return keccak256(bytes(step)) == keccak256(bytes("broadcast"));
    }

    function _readAddress(string memory key) internal view returns (address) {
        if (!_resumeEnabled) {
            return address(0);
        }
        return _tryReadDeployment(_artifactEnv, key);
    }

    function _readFlag(string memory key) internal view returns (bool value, bool found) {
        if (!_resumeEnabled) {
            return (false, false);
        }
        return _tryReadDeploymentFlag(_artifactEnv, key);
    }

    function _isStaleLocalDeployment(DeployConfig memory config) internal view returns (bool) {
        string[21] memory keys = [
            "AtomicProxyFactory",
            "OllaGovernanceImplementation",
            "OllaGovernanceProxy",
            "OllaCoreImplementation",
            "OllaCoreProxy",
            "OllaVaultImplementation",
            "OllaVaultProxy",
            "Asset",
            "MockAztecRollup",
            "MockAztecRollupRegistry",
            "StAztec",
            "EndpointV2Mock",
            "StAztecOFTAdapter",
            "WithdrawalQueueImplementation",
            "WithdrawalQueueProxy",
            "RewardsAccumulatorImplementation",
            "RewardsAccumulatorProxy",
            "StakingManagerImplementation",
            "StakingManagerProxy",
            "StakingProviderRegistryImplementation",
            "StakingProviderRegistryProxy"
        ];

        for (uint256 i; i < keys.length; ++i) {
            address existing = _tryReadDeployment(config.name, keys[i]);
            if (existing != address(0) && existing.code.length == 0) {
                return true;
            }
        }

        address safetyModule = _tryReadDeployment(config.name, "SafetyModule");
        if (safetyModule != address(0) && safetyModule.code.length == 0) {
            return true;
        }

        return false;
    }

    function _enforceOperatorFlowGuardrails(DeployConfig memory config) internal view {
        if (!_isStrictChain(config.chainId)) return;

        string memory step = vm.envOr("DEPLOY_STEP", string(""));
        require(
            keccak256(bytes(step)) == keccak256(bytes("dry-run"))
                || keccak256(bytes(step)) == keccak256(bytes("broadcast")),
            "Deploy: DEPLOY_STEP must be dry-run or broadcast"
        );

        if (keccak256(bytes(step)) == keccak256(bytes("dry-run"))) {
            require(
                !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast),
                "Deploy: dry-run step cannot be executed with --broadcast"
            );
        }

        if (keccak256(bytes(step)) == keccak256(bytes("broadcast"))) {
            require(vm.envOr("DEPLOY_DRY_RUN_DONE", false), "Deploy: run dry-run first");
            require(vm.envOr("DEPLOY_WITH_VERIFY", false), "Deploy: broadcast requires verify intent");
        }
    }

    function _validateRealAztecDependencies(address asset, address rollupRegistry) internal view {
        require(asset.code.length > 0, "Deploy: asset must be contract");
        require(rollupRegistry.code.length > 0, "Deploy: rollupRegistry must be contract");

        address canonicalRollup = IAztecRollupRegistry(rollupRegistry).getCanonicalRollup();
        require(canonicalRollup != address(0), "Deploy: canonical rollup missing");
        require(canonicalRollup.code.length > 0, "Deploy: canonical rollup must be contract");

        address rollupGovernance = IAztecRollupRegistry(rollupRegistry).getGovernance();
        require(rollupGovernance != address(0), "Deploy: rollup governance missing");

        uint256 activationThreshold = IAztecRollup(canonicalRollup).getActivationThreshold();
        require(activationThreshold > 0, "Deploy: invalid canonical rollup");

        IAztecRollup(canonicalRollup).isRewardsClaimable();
    }

    function _predictProxyAddress(address implementation, bytes32 salt) internal view returns (address) {
        return _atomicProxyFactory.computeAddress(implementation, salt);
    }

    function _validateDeploymentState(
        DeployConfig memory config,
        address asset,
        address rollupRegistry,
        address ollaGovProxy,
        address ollaCoreProxy,
        address ollaVaultProxy,
        address stakingManager,
        address stakingProviderRegistry,
        address withdrawalQueue,
        address rewardsAccumulator,
        address safetyModule
    ) internal view {
        require(OllaGovernance(payable(ollaGovProxy)).core() == ollaCoreProxy, "Deploy: governance core mismatch");
        require(OllaCore(ollaCoreProxy).owner() == ollaGovProxy, "Deploy: core owner mismatch");
        require(OllaVault(ollaVaultProxy).owner() == ollaGovProxy, "Deploy: vault owner mismatch");

        require(OllaCore(ollaCoreProxy).asset() == asset, "Deploy: core asset mismatch");
        if (_isStrictChain(config.chainId)) {
            address currentVault = OllaCore(ollaCoreProxy).vault();
            require(currentVault == address(0) || currentVault == ollaVaultProxy, "Deploy: core vault mismatch");
        } else if (config.timelockMinDelay == 0) {
            require(OllaCore(ollaCoreProxy).vault() == ollaVaultProxy, "Deploy: core vault mismatch");
        } else {
            require(OllaCore(ollaCoreProxy).vault() == address(0), "Deploy: core vault should be unset");
        }
        require(OllaCore(ollaCoreProxy).stakingManager() == stakingManager, "Deploy: core stakingManager mismatch");
        require(
            OllaCore(ollaCoreProxy).rewardsAccumulator() == rewardsAccumulator,
            "Deploy: core rewardsAccumulator mismatch"
        );
        require(OllaCore(ollaCoreProxy).safetyModule() == safetyModule, "Deploy: core safetyModule mismatch");

        require(OllaVault(ollaVaultProxy).core() == ollaCoreProxy, "Deploy: vault core mismatch");
        require(OllaVault(ollaVaultProxy).asset() == asset, "Deploy: vault asset mismatch");
        require(OllaVault(ollaVaultProxy).withdrawalQueue() == withdrawalQueue, "Deploy: vault queue mismatch");
        require(OllaVault(ollaVaultProxy).safetyModule() == safetyModule, "Deploy: vault safetyModule mismatch");

        require(
            StakingManager(stakingManager).rollupRegistry() == IAztecRollupRegistry(rollupRegistry),
            "Deploy: staking rollupRegistry mismatch"
        );
        require(StakingManager(stakingManager).core() == ollaCoreProxy, "Deploy: staking core mismatch");
        require(
            address(StakingManager(stakingManager).stakingProviderRegistry()) == stakingProviderRegistry,
            "Deploy: staking providerRegistry mismatch"
        );

        require(WithdrawalQueue(withdrawalQueue).vault() == ollaVaultProxy, "Deploy: queue vault mismatch");
        require(IRewardsAccumulator(rewardsAccumulator).core() == ollaCoreProxy, "Deploy: rewards core mismatch");

        bytes32 defaultAdminRole = 0x00;
        bytes32 guardianRole = OllaCore(ollaCoreProxy).GUARDIAN_ROLE();
        require(
            AccessControlUpgradeable(ollaCoreProxy).hasRole(defaultAdminRole, ollaGovProxy),
            "Deploy: core admin role mismatch"
        );
        require(
            AccessControlUpgradeable(ollaCoreProxy).hasRole(guardianRole, ollaGovProxy),
            "Deploy: core guardian role mismatch"
        );
        require(
            AccessControlUpgradeable(ollaVaultProxy).hasRole(defaultAdminRole, ollaGovProxy),
            "Deploy: vault admin role mismatch"
        );
        require(
            AccessControlUpgradeable(ollaVaultProxy).hasRole(OllaVault(ollaVaultProxy).GUARDIAN_ROLE(), ollaGovProxy),
            "Deploy: vault guardian role mismatch"
        );

        if (_isStrictChain(config.chainId) && !config.deployMocks) {
            require(
                !AccessControlUpgradeable(ollaGovProxy).hasRole(defaultAdminRole, config.deployer),
                "Deploy: deployer still admin on governance"
            );
            require(
                !AccessControlUpgradeable(safetyModule)
                    .hasRole(SafetyModule(safetyModule).GUARDIAN_ROLE(), config.deployer),
                "Deploy: deployer must not retain guardian"
            );
        }

        if (!_isStrictChain(config.chainId) && config.timelockMinDelay > 0) {
            require(OllaCore(ollaCoreProxy).paused(), "Deploy: core should remain paused");
            require(OllaVault(ollaVaultProxy).paused(), "Deploy: vault should remain paused");
        }
    }

    function _requireSafeGovernanceRoleHandover(address governance, address deployer, address configuredGovernance)
        internal
        view
    {
        OllaGovernance gov = OllaGovernance(payable(governance));

        // If deployer does not currently hold operational roles, there is nothing to hand over.
        bool deployerHasOperationalRole =
            AccessControlUpgradeable(governance).hasRole(gov.PROPOSER_ROLE(), deployer)
            || AccessControlUpgradeable(governance).hasRole(gov.EXECUTOR_ROLE(), deployer)
            || AccessControlUpgradeable(governance).hasRole(gov.CANCELLER_ROLE(), deployer);
        if (!deployerHasOperationalRole) return;

        require(
            AccessControlUpgradeable(governance).hasRole(gov.PROPOSER_ROLE(), configuredGovernance),
            "Deploy: configured governance missing PROPOSER_ROLE"
        );
        require(
            AccessControlUpgradeable(governance).hasRole(gov.EXECUTOR_ROLE(), configuredGovernance)
                || AccessControlUpgradeable(governance).hasRole(gov.EXECUTOR_ROLE(), address(0)),
            "Deploy: configured governance missing EXECUTOR_ROLE"
        );
        require(
            AccessControlUpgradeable(governance).hasRole(gov.CANCELLER_ROLE(), configuredGovernance),
            "Deploy: configured governance missing CANCELLER_ROLE"
        );
    }

    function _assertGovernanceOperationalRoles(address governance, address deployer, address configuredGovernance)
        internal
        view
    {
        OllaGovernance gov = OllaGovernance(payable(governance));

        bool proposerExists =
            AccessControlUpgradeable(governance).hasRole(gov.PROPOSER_ROLE(), configuredGovernance)
            || AccessControlUpgradeable(governance).hasRole(gov.PROPOSER_ROLE(), deployer);
        bool executorExists =
            AccessControlUpgradeable(governance).hasRole(gov.EXECUTOR_ROLE(), configuredGovernance)
            || AccessControlUpgradeable(governance).hasRole(gov.EXECUTOR_ROLE(), deployer)
            || AccessControlUpgradeable(governance).hasRole(gov.EXECUTOR_ROLE(), address(0));
        bool cancellerExists =
            AccessControlUpgradeable(governance).hasRole(gov.CANCELLER_ROLE(), configuredGovernance)
            || AccessControlUpgradeable(governance).hasRole(gov.CANCELLER_ROLE(), deployer);

        require(proposerExists, "Deploy: no proposer role holder after deployment");
        require(executorExists, "Deploy: no executor role holder after deployment");
        require(cancellerExists, "Deploy: no canceller role holder after deployment");
    }

    function _isStrictChain(uint256 chainId) internal pure returns (bool) {
        return chainId == _CHAIN_SEPOLIA || chainId == _CHAIN_MAINNET;
    }

    function _shouldFailFastOnMissingResumeCode(DeployConfig memory config) internal pure returns (bool) {
        // Local/dev resume flows can carry stale no-code addresses from partial runs or simulated dry-runs.
        // We clear and redeploy in those environments to keep iteration smooth.
        // On strict chains (Sepolia/Mainnet), no-code addresses indicate a dangerous artifact/RPC mismatch,
        // so we fail fast instead of silently redeploying.
        return _isStrictChain(config.chainId);
    }

    function _validateAddressSeparation(DeployConfig memory config) internal pure {
        if (!_isStrictChain(config.chainId)) return;
        if (config.deployMocks) return;

        require(config.deployer != config.governance, "Deploy: deployer must differ from governance");
        require(config.deployer != config.treasury, "Deploy: deployer must differ from treasury");
        require(config.deployer != config.providerAdmin, "Deploy: deployer must differ from providerAdmin");
        require(config.deployer != config.guardian, "Deploy: deployer must differ from guardian");
        require(config.governance != config.providerAdmin, "Deploy: governance must differ from providerAdmin");
    }
}
