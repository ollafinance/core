// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";
import { DeployScript } from "script/Deploy.s.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { AtomicProxyFactory } from "script/deployers/AtomicProxyFactory.sol";

contract DeployResumeTest is Test {
    string internal constant _DEPLOYMENT_PATH = "deployments/local.json";
    string internal constant _ANVIL_PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

    function setUp() external {
        vm.chainId(31337);

        if (vm.exists(_DEPLOYMENT_PATH)) {
            vm.removeFile(_DEPLOYMENT_PATH);
        }

        vm.setEnv("ETHEREUM_CHAIN_ID", "31337");
        vm.setEnv("MOCK_AZTEC", "true");
        vm.setEnv("DEPLOY_STEP", "broadcast");
        vm.setEnv("DEPLOY_DRY_RUN_DONE", "true");
        vm.setEnv("DEPLOY_WITH_VERIFY", "true");
        vm.setEnv("DEPLOY_ALLOW_ARTIFACT_WRITE", "true");
        vm.setEnv("PRIVATE_KEY", _ANVIL_PK);
        vm.setEnv("LZ_ENDPOINT", "0x0000000000000000000000000000000000000000");
    }

    function test_deployResumeScenarios() external {
        DeployScript deploy = _runDeploy();

        string memory first = vm.readFile(_DEPLOYMENT_PATH);
        address firstCoreImpl = vm.parseJsonAddress(first, ".addresses.OllaCoreImplementation");
        address firstCore = vm.parseJsonAddress(first, ".addresses.OllaCoreProxy");
        address firstVaultImpl = vm.parseJsonAddress(first, ".addresses.OllaVaultImplementation");
        address firstVault = vm.parseJsonAddress(first, ".addresses.OllaVaultProxy");
        address firstFactory = vm.parseJsonAddress(first, ".addresses.AtomicProxyFactory");
        address firstAsset = vm.parseJsonAddress(first, ".addresses.Asset");
        address firstStAztec = vm.parseJsonAddress(first, ".addresses.StAztec");
        address firstStakingManager = vm.parseJsonAddress(first, ".addresses.StakingManagerProxy");
        address firstRewardsAccumulator = vm.parseJsonAddress(first, ".addresses.RewardsAccumulatorProxy");
        address firstSafetyModule = vm.parseJsonAddress(first, ".addresses.SafetyModule");
        address firstWithdrawalQueue = vm.parseJsonAddress(first, ".addresses.WithdrawalQueueProxy");
        address firstGovernance = vm.parseJsonAddress(first, ".addresses.OllaGovernanceProxy");
        bool firstCompleted = vm.parseJsonBool(first, ".status.completed");
        string memory firstPhase = vm.parseJsonString(first, ".status.phase");

        assertEq(deploy.predictCoreProxy(firstCoreImpl), firstCore, "core proxy should match deterministic prediction");
        assertEq(
            deploy.predictVaultProxy(firstVaultImpl), firstVault, "vault proxy should match deterministic prediction"
        );
        assertEq(AtomicProxyFactory(firstFactory).DEPLOYER(), vm.addr(vm.envUint("PRIVATE_KEY")), "factory deployer");

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(AtomicProxyFactory.AtomicProxyFactory__UnauthorizedCaller.selector, attacker)
        );
        AtomicProxyFactory(firstFactory)
            .deployVaultAndInitialize(
                address(0), bytes32(0), IERC20(address(0)), IStAztec(address(0)), address(0), address(0), address(0)
            );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        OllaCore(firstCore)
            .initialize(
                IERC20(firstAsset),
                IStAztec(firstStAztec),
                IStakingManager(firstStakingManager),
                500,
                5000,
                firstGovernance,
                IRewardsAccumulator(firstRewardsAccumulator),
                firstSafetyModule
            );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        OllaVault(firstVault)
            .initialize(IERC20(firstAsset), IStAztec(firstStAztec), firstWithdrawalQueue, firstCore, firstGovernance);

        _runDeploy();

        string memory second = vm.readFile(_DEPLOYMENT_PATH);
        address secondCore = vm.parseJsonAddress(second, ".addresses.OllaCoreProxy");
        address secondVault = vm.parseJsonAddress(second, ".addresses.OllaVaultProxy");
        bool secondCompleted = vm.parseJsonBool(second, ".status.completed");
        string memory secondPhase = vm.parseJsonString(second, ".status.phase");

        assertEq(firstCore, secondCore, "core proxy changed on resume");
        assertEq(firstVault, secondVault, "vault proxy changed on resume");
        assertTrue(firstCompleted, "first run should complete");
        assertTrue(secondCompleted, "second run should complete");
        assertEq(firstPhase, "D", "first phase should be D");
        assertEq(secondPhase, "D", "second phase should be D");

        vm.writeJson('"0x0000000000000000000000000000000000000001"', _DEPLOYMENT_PATH, ".addresses.OllaCoreProxy");
        _runDeploy();
        string memory third = vm.readFile(_DEPLOYMENT_PATH);
        address thirdCore = vm.parseJsonAddress(third, ".addresses.OllaCoreProxy");
        assertTrue(thirdCore != address(1), "stale local artifact should be reset");

        vm.removeFile(_DEPLOYMENT_PATH);
        _runDeploy();

        vm.setEnv("PRIVATE_KEY", "1");
        deploy = new DeployScript();
        deploy.setUp();
        vm.expectRevert(bytes("Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.deployer"));
        deploy.run();
    }

    function _runDeploy() internal returns (DeployScript deploy) {
        deploy = new DeployScript();
        deploy.setUp();
        deploy.run();
    }
}
