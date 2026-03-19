// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";
import { DeployScript } from "script/Deploy.s.sol";

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
        _runDeploy();

        string memory first = vm.readFile(_DEPLOYMENT_PATH);
        address firstCore = vm.parseJsonAddress(first, ".addresses.OllaCoreProxy");
        address firstVault = vm.parseJsonAddress(first, ".addresses.OllaVaultProxy");
        bool firstCompleted = vm.parseJsonBool(first, ".status.completed");
        string memory firstPhase = vm.parseJsonString(first, ".status.phase");

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
        DeployScript deploy = new DeployScript();
        deploy.setUp();
        vm.expectRevert(bytes("Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.deployer"));
        deploy.run();
    }

    function _runDeploy() internal {
        DeployScript deploy = new DeployScript();
        deploy.setUp();
        deploy.run();
    }
}
