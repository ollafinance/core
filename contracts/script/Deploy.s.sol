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

interface ILayerZeroEndpointV2Delegates {
    function delegates(address oapp) external view returns (address delegate);
}

/// @title DeployScript
/// @notice Main deployment orchestrator - deploys all contracts based on environment
contract DeployScript is BaseDeployer {
    uint256 internal constant _CHAIN_LOCAL = 31337;
    uint256 internal constant _CHAIN_SEPOLIA = 11155111;
    uint256 internal constant _CHAIN_MAINNET = 1;

    // Canonical LayerZero EndpointV2 addresses per chain (defense-in-depth allowlist).
    // Sourced from in-repo .example-mainnet.env / .example-sepolia.env and deployments/{mainnet,sepolia}.json.
    address internal constant _CANONICAL_LZ_ENDPOINT_MAINNET = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant _CANONICAL_LZ_ENDPOINT_SEPOLIA = 0x6EDCE65403992e310A62460808c4b910D972f10f;

    bytes32 internal constant _CORE_PROXY_SALT = keccak256("olla.core.proxy.v1_1");
    bytes32 internal constant _VAULT_PROXY_SALT = keccak256("olla.vault.proxy.v1_1");
    bytes32 internal constant _STAKING_MANAGER_PROXY_SALT = keccak256("olla.staking.manager.proxy.v1_1");
    bytes32 internal constant _STAKING_PROVIDER_REGISTRY_PROXY_SALT =
        keccak256("olla.staking.providerRegistry.proxy.v1_1");

    // Deployers
    MocksDeployer internal _mocksDeployer;
    OllaCoreDeployer internal _ollaCoreDeployer;
    OllaGovernanceDeployer internal _ollaGovernanceDeployer;
    OllaVaultDeployer internal _ollaVaultDeployer;
    StAztecDeployer internal _stAztecDeployer;
    StAztecOFTAdapterDeployer internal _stAztecOFTAdapterDeployer;
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
        _rewardsAccumulatorDeployer = new RewardsAccumulatorDeployer();
        // _stakingStackDeployer is created after _atomicProxyFactory is resolved in run() because
        // it now routes proxy creation through the factory to avoid the front-run window between
        // proxy CREATE and initialize() (mainnet incident 2026-05-11).
    }

    function run() public {
        // Load config based on ETHEREUM_CHAIN_ID
        DeployConfig memory config = _loadConfig();
        require(block.chainid == config.chainId, "Deploy: ETHEREUM_CHAIN_ID/RPC chain mismatch");

        _validateAddressSeparation(config);
        _enforceOperatorFlowGuardrails(config);

        _resetLocalArtifactIfStale(config);
        _stageDeploymentArtifactWrites(config.name);

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
        address rewardsAccumulator;
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
            // Persist/validate every security-relevant role and config input under `.inputs` so a
            // corrected strict-chain rerun cannot complete while reusing stale privileged inputs (#431).
            _ensureRoleConfigCompatibility(_artifactEnv, config);
        }
        _atomicProxyFactory = _resolveOrDeployAtomicProxyFactory(config);
        _ollaCoreDeployer = new OllaCoreDeployer(_atomicProxyFactory);
        _ollaVaultDeployer = new OllaVaultDeployer(_atomicProxyFactory);
        _stakingStackDeployer = new StakingStackDeployer(_atomicProxyFactory);

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

        // On strict non-mock chains the bridge is mandatory: the endpoint must be the canonical
        // LayerZero EndpointV2 for the chain (defense-in-depth against a fake endpoint binding) and
        // the deployment may not complete without the adapter (#434/#448).
        bool bridgeRequired = _isStrictChain(config.chainId) && !config.deployMocks;
        if (bridgeRequired) {
            _validateCanonicalLzEndpoint(config.chainId, lzEndpoint);
        }

        if (lzEndpoint != address(0)) {
            address oftDelegate = config.deployMocks ? config.deployer : ollaGovProxy;
            oftAdapter = _resolveOrDeployOftAdapter(config, stAztec, lzEndpoint, oftDelegate);
        }

        if (bridgeRequired) {
            require(oftAdapter != address(0), "Deploy: StAztecOFTAdapter required on strict non-mock chain");
        }

        // 5.1 Deploy RewardsAccumulator (linked to OllaCore proxy)

        (rewardsAccumulatorImpl, rewardsAccumulator) =
            _resolveOrDeployRewardsAccumulator(config, asset, predictedCoreProxy, ollaGovProxy);

        // 6. Deploy staking stack: StakingManager + StakingProviderRegistry behind proxies.
        // Proxy CREATE and both initialize() calls are wrapped in a single factory call so the
        // pair is never observable in an uninitialized state.
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
        config.rewardsAccumulator = rewardsAccumulator;
        config.safetyModule = safetyModule;
        config.governance = ollaGovProxy;
        ollaCoreProxy = _resolveOrDeployOllaCoreProxy(
            config, ollaCoreImpl, asset, stAztec, stakingManager, safetyModule, _CORE_PROXY_SALT
        );
        ollaVaultProxy = _resolveOrDeployOllaVaultProxy(
            config, ollaVaultImpl, asset, stAztec, ollaCoreProxy, ollaGovProxy, _VAULT_PROXY_SALT
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
            rewardsAccumulator,
            safetyModule
        );

        _validateBridgeDeploymentState(config, stAztec, lzEndpoint, oftAdapter, ollaGovProxy);

        // Add StAztec metadata for frontend signature generation
        string memory stAztecName = StAztec(stAztec).name();

        // Get version from EIP712 domain
        (,, string memory stAztecVersion,,,,) = IERC5267(stAztec).eip712Domain();

        _recordMetadataString("stAztecName", stAztecName);
        _recordMetadataString("stAztecVersion", stAztecVersion);
        _setPhase("D", true);
        _commitDeploymentArtifactWrites(config.name);
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
            _validateReusedGovernanceState(config, proxy);
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
            _validateReusedCoreFeeState(config, proxy);
            _recordFlag("coreInitialized", true);
            return proxy;
        }

        // The artifact key is absent (e.g. a prior retry deployed the deterministic proxy into a
        // staged artifact that was lost before commit). If the predicted CREATE2 address already has
        // code, adopt it after validation instead of replaying the deploy into a collision (#463).
        address predicted = _predictProxyAddress(implementation, salt);
        if (_hasCode(predicted)) {
            _assertCoreInitialized(
                predicted, asset, stAztec, stakingManager, config.rewardsAccumulator, safetyModule, config.governance
            );
            _validateReusedCoreFeeState(config, predicted);
            _recordAddress("OllaCoreProxy", predicted);
            _recordFlag("coreInitialized", true);
            return predicted;
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
            _assertVaultInitialized(proxy, asset, core, governance);
            _recordFlag("vaultInitialized", true);
            return proxy;
        }

        // Adopt a previously-deployed deterministic proxy at the predicted CREATE2 address if its
        // record was lost across a retry, rather than redeploying into a collision (#463).
        address predicted = _predictProxyAddress(implementation, salt);
        if (_hasCode(predicted)) {
            _assertVaultInitialized(predicted, asset, core, governance);
            _recordAddress("OllaVaultProxy", predicted);
            _recordFlag("vaultInitialized", true);
            return predicted;
        }

        (/*implementation*/, proxy) =
            _ollaVaultDeployer.deploy(config, implementation, asset, stAztec, core, governance, salt);
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

        // After a FRESH adapter deployment validate the on-chain binding so a strict deploy cannot
        // silently record an adapter wired to the wrong token/endpoint/owner/delegate (#448).
        if (_isStrictChain(config.chainId) && !config.deployMocks) {
            require(
                _matchesOftAdapter(adapter, stAztec, lzEndpoint, delegate),
                "Deploy: ADDRESS_STATE_MISMATCH.StAztecOFTAdapter.binding"
            );
        }

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
            _validateReusedProviderRegistryState(config, stakingProviderRegistryProxy);
            return (stakingManagerImpl, stakingManagerProxy, stakingProviderRegistryImpl, stakingProviderRegistryProxy);
        }

        // Adopt a previously-deployed deterministic staking pair if its proxy records were lost across
        // a retry but the implementations (which seed the CREATE2 salt) are still recorded. Re-deploying
        // the pair into the same predicted addresses would collide (#463).
        {
            address recordedManagerImpl = _readAddress("StakingManagerImplementation");
            address recordedRegistryImpl = _readAddress("StakingProviderRegistryImplementation");
            if (recordedManagerImpl != address(0) && _hasCode(recordedManagerImpl) && recordedRegistryImpl != address(0)
                && _hasCode(recordedRegistryImpl)) {
                address predictedManager = _predictProxyAddress(recordedManagerImpl, _STAKING_MANAGER_PROXY_SALT);
                address predictedRegistry =
                    _predictProxyAddress(recordedRegistryImpl, _STAKING_PROVIDER_REGISTRY_PROXY_SALT);
                if (_hasCode(predictedManager) && _hasCode(predictedRegistry)) {
                    _assertStakingStackInitialized(
                        config,
                        predictedManager,
                        predictedRegistry,
                        core,
                        rewardsAccumulator,
                        asset,
                        rollupRegistry,
                        governanceAdmin
                    );
                    _recordAddress("StakingManagerImplementation", recordedManagerImpl);
                    _recordAddress("StakingManagerProxy", predictedManager);
                    _recordAddress("StakingProviderRegistryImplementation", recordedRegistryImpl);
                    _recordAddress("StakingProviderRegistryProxy", predictedRegistry);
                    return (recordedManagerImpl, predictedManager, recordedRegistryImpl, predictedRegistry);
                }
            }
        }

        (stakingManagerImpl, stakingManagerProxy, stakingProviderRegistryImpl, stakingProviderRegistryProxy) = _stakingStackDeployer.deploy(
            config,
            core,
            rewardsAccumulator,
            asset,
            rollupRegistry,
            governanceAdmin,
            _STAKING_MANAGER_PROXY_SALT,
            _STAKING_PROVIDER_REGISTRY_PROXY_SALT
        );
        require(
            stakingManagerProxy == _predictProxyAddress(stakingManagerImpl, _STAKING_MANAGER_PROXY_SALT),
            "Deploy: ADDRESS_STATE_MISMATCH.StakingManagerProxy.predicted"
        );
        require(
            stakingProviderRegistryProxy
                == _predictProxyAddress(stakingProviderRegistryImpl, _STAKING_PROVIDER_REGISTRY_PROXY_SALT),
            "Deploy: ADDRESS_STATE_MISMATCH.StakingProviderRegistryProxy.predicted"
        );
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
            _validateReusedSafetyModuleState(config, safetyModule);
            return safetyModule;
        }

        vm.startBroadcast(config.deployerPrivateKey);
        safetyModule = address(
            new SafetyModule(
                admin,
                config.guardian,
                core,
                vault,
                config.safetyDepositCap,
                config.safetyMinRateDropBps,
                config.safetyMaxQueueRatioBps,
                config.safetyMaxAccountingDelay
            )
        );
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
        address currentCore = OllaGovernance(payable(governance)).core();
        if (config.timelockMinDelay == 0) {
            require(currentCore == core, "Deploy: ADDRESS_STATE_MISMATCH.Governance.core.after");
        } else if (currentCore == address(0)) {
            _logInfo("OllaGovernance.setCore(OllaCore) scheduled or pending governance execution");
        } else {
            require(currentCore == core, "Deploy: ADDRESS_STATE_MISMATCH.Governance.core.after");
        }
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

    /// @notice Persists (first run) and validates (resume) every security-relevant role/config input
    /// under `.inputs`. On a strict-chain resume where the current env value differs from the persisted
    /// artifact value, this reverts with CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.<key> (#431).
    function _ensureRoleConfigCompatibility(string memory env, DeployConfig memory config) internal {
        string memory path = _getDeploymentPath(env);
        if (!vm.isFile(path)) {
            return;
        }
        string memory existing = vm.readFile(path);

        // Privileged role addresses.
        _ensureInputAddressCompatibility(path, existing, "governance", config.governance);
        _ensureInputAddressCompatibility(path, existing, "treasury", config.treasury);
        _ensureInputAddressCompatibility(path, existing, "providerAdmin", config.providerAdmin);
        _ensureInputAddressCompatibility(path, existing, "providerRewardsRecipient", config.providerRewardsRecipient);
        _ensureInputAddressCompatibility(path, existing, "guardian", config.guardian);

        // Privileged / economic uint parameters.
        _ensureInputUintCompatibility(path, existing, "timelockMinDelay", config.timelockMinDelay);
        _ensureInputUintCompatibility(path, existing, "protocolFeeBP", config.protocolFeeBP);
        _ensureInputUintCompatibility(path, existing, "treasuryFeeSplitBP", config.treasuryFeeSplitBP);
        _ensureInputUintCompatibility(path, existing, "safetyDepositCap", config.safetyDepositCap);
        _ensureInputUintCompatibility(path, existing, "safetyMinRateDropBps", config.safetyMinRateDropBps);
        _ensureInputUintCompatibility(path, existing, "safetyMaxQueueRatioBps", config.safetyMaxQueueRatioBps);
        _ensureInputUintCompatibility(path, existing, "safetyMaxAccountingDelay", config.safetyMaxAccountingDelay);
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

    function _assertVaultInitialized(address vault, address asset, address core, address governance) internal view {
        require(OllaVault(vault).owner() == governance, "Deploy: ADDRESS_STATE_MISMATCH.OllaVault.owner");
        require(OllaVault(vault).asset() == asset, "Deploy: ADDRESS_STATE_MISMATCH.OllaVault.asset");
        require(OllaVault(vault).core() == core, "Deploy: ADDRESS_STATE_MISMATCH.OllaVault.core");
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
        if (vm.envExists("DEPLOY_RESUME")) {
            return vm.envBool("DEPLOY_RESUME");
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
        string[19] memory keys = [
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
        address rewardsAccumulator,
        address safetyModule
    ) internal view {
        if (config.timelockMinDelay == 0) {
            require(OllaGovernance(payable(ollaGovProxy)).core() == ollaCoreProxy, "Deploy: governance core mismatch");
        } else {
            require(
                OllaGovernance(payable(ollaGovProxy)).core() == address(0), "Deploy: governance core should be unset"
            );
        }
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

    /// @notice Validates live OllaGovernance state (treasury, timelock min delay, governanceAdmin)
    /// against current config before reusing an existing governance module on resume (#431).
    function _validateReusedGovernanceState(DeployConfig memory config, address governanceProxy) internal view {
        if (!_shouldValidateReusedLiveState(config)) {
            return;
        }
        OllaGovernance gov = OllaGovernance(payable(governanceProxy));
        require(gov.treasury() == config.treasury, "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.treasury");
        require(
            gov.getMinDelay() == config.timelockMinDelay,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.timelockMinDelay"
        );
        require(
            gov.governanceAdmin() == config.governance,
            "Deploy: ADDRESS_STATE_MISMATCH.OllaGovernance.governanceAdmin"
        );
    }

    /// @notice Validates live SafetyModule state (guardian role + safety parameters) against current
    /// config before reusing an existing SafetyModule on resume (#431).
    function _validateReusedSafetyModuleState(DeployConfig memory config, address safetyModule) internal view {
        if (!_shouldValidateReusedLiveState(config)) {
            return;
        }
        SafetyModule sm = SafetyModule(safetyModule);
        require(
            AccessControlUpgradeable(safetyModule).hasRole(sm.GUARDIAN_ROLE(), config.guardian),
            "Deploy: ADDRESS_STATE_MISMATCH.SafetyModule.guardian"
        );
        require(
            sm.depositCap() == config.safetyDepositCap,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.safetyDepositCap"
        );
        require(
            sm.minRateDropBps() == config.safetyMinRateDropBps,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.safetyMinRateDropBps"
        );
        require(
            sm.maxQueueRatioBps() == config.safetyMaxQueueRatioBps,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.safetyMaxQueueRatioBps"
        );
        require(
            sm.maxAccountingDelay() == config.safetyMaxAccountingDelay,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.safetyMaxAccountingDelay"
        );
    }

    /// @notice Validates live StakingProviderRegistry state (provider-admin role + rewards recipient)
    /// against current config before reusing an existing registry on resume (#431).
    function _validateReusedProviderRegistryState(DeployConfig memory config, address providerRegistry) internal view {
        if (!_shouldValidateReusedLiveState(config)) {
            return;
        }
        StakingProviderRegistry registry = StakingProviderRegistry(providerRegistry);
        require(
            AccessControlUpgradeable(providerRegistry)
                .hasRole(registry.STAKING_PROVIDER_ADMIN_ROLE(), config.providerAdmin),
            "Deploy: ADDRESS_STATE_MISMATCH.StakingProviderRegistry.providerAdmin"
        );
        require(
            registry.getStakingProviderConfig().rewardsRecipient == config.providerRewardsRecipient,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.providerRewardsRecipient"
        );
    }

    /// @notice Validates live OllaCore fee parameters against current config before reusing an existing
    /// OllaCore proxy on resume (#431).
    function _validateReusedCoreFeeState(DeployConfig memory config, address coreProxy) internal view {
        if (!_shouldValidateReusedLiveState(config)) {
            return;
        }
        require(
            OllaCore(coreProxy).protocolFeeBP() == config.protocolFeeBP,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.protocolFeeBP"
        );
        require(
            OllaCore(coreProxy).treasuryFeeSplitBP() == config.treasuryFeeSplitBP,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.treasuryFeeSplitBP"
        );
    }

    /// @notice Validates a staking pair (manager + registry) is fully and correctly initialized.
    /// Mirrors the resume-reuse checks; used when adopting a deterministic pair recovered by predicted
    /// CREATE2 address after a lost retry record (#463).
    function _assertStakingStackInitialized(
        DeployConfig memory config,
        address stakingManagerProxy,
        address stakingProviderRegistryProxy,
        address core,
        address rewardsAccumulator,
        address asset,
        address rollupRegistry,
        address governanceAdmin
    ) internal view {
        require(StakingManager(stakingManagerProxy).core() == core, "Deploy: ADDRESS_STATE_MISMATCH.StakingManager.core");
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
        _validateReusedProviderRegistryState(config, stakingProviderRegistryProxy);
    }

    /// @notice Enforces that, when the bridge is required, the configured LayerZero endpoint is the
    /// canonical EndpointV2 for the chain and is a deployed contract (defense-in-depth, #448).
    function _validateCanonicalLzEndpoint(uint256 chainId, address lzEndpoint) internal view {
        require(lzEndpoint != address(0), "Deploy: lzEndpoint required on strict non-mock chain");

        address expected;
        if (chainId == _CHAIN_MAINNET) {
            expected = _CANONICAL_LZ_ENDPOINT_MAINNET;
        } else if (chainId == _CHAIN_SEPOLIA) {
            expected = _CANONICAL_LZ_ENDPOINT_SEPOLIA;
        } else {
            revert("Deploy: no canonical LZ endpoint for chain");
        }

        require(lzEndpoint == expected, "Deploy: LZ_ENDPOINT is not the canonical LayerZero EndpointV2");
        require(lzEndpoint.code.length > 0, "Deploy: LZ_ENDPOINT must be a deployed contract");
    }

    /// @notice Validates the bridge (StAztecOFTAdapter + LayerZero endpoint) as part of final
    /// deployment-state validation so a missing or mis-bound adapter cannot pass as complete (#434/#448).
    function _validateBridgeDeploymentState(
        DeployConfig memory config,
        address stAztec,
        address lzEndpoint,
        address oftAdapter,
        address ollaGovProxy
    ) internal view {
        if (!(_isStrictChain(config.chainId) && !config.deployMocks)) {
            return;
        }

        _validateCanonicalLzEndpoint(config.chainId, lzEndpoint);
        require(oftAdapter != address(0), "Deploy: StAztecOFTAdapter required on strict non-mock chain");
        require(oftAdapter.code.length > 0, "Deploy: StAztecOFTAdapter must be a deployed contract");
        require(
            _matchesOftAdapter(oftAdapter, stAztec, lzEndpoint, ollaGovProxy),
            "Deploy: ADDRESS_STATE_MISMATCH.StAztecOFTAdapter"
        );
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

    /// @notice True when reused modules must be re-validated against current config/role inputs on
    /// resume (strict non-mock chains only). Mock/local resume flows iterate freely and are exempt.
    function _shouldValidateReusedLiveState(DeployConfig memory config) internal pure returns (bool) {
        return _isStrictChain(config.chainId) && !config.deployMocks;
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
