//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../src/testAZTEC.sol";
import "../src/MinimalVault.sol";
import "../src/GuardianPause.sol";
import "../src/StakingStub.sol";
import "./DeployHelpers.s.sol";

/**
 * @notice Main deployment script for all contracts
 * @dev Run this when you want to deploy multiple contracts at once
 *
 * Example: yarn deploy # runs this script(without`--file` flag)
 */
contract DeployScript is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        // Deploy testAZTEC token first
        testAZTEC testAztec = new testAZTEC();
        console.logString(string.concat("testAZTEC deployed at: ", vm.toString(address(testAztec))));

        // Deploy GuardianPause (guardian is the deployer for now)
        GuardianPause guardianPause = new GuardianPause(deployer);
        console.logString(string.concat("GuardianPause deployed at: ", vm.toString(address(guardianPause))));

        // Deploy MinimalVault with testAZTEC token, internal operator (deployer), and guardian
        MinimalVault minimalVault = new MinimalVault(address(testAztec), deployer, deployer);
        console.logString(string.concat("MinimalVault deployed at: ", vm.toString(address(minimalVault))));

        // Deploy StakingStub with testAZTEC token and deployer as owner
        StakingStub stakingStub = new StakingStub(address(testAztec), deployer);
        console.logString(string.concat("StakingStub deployed at: ", vm.toString(address(stakingStub))));

        // Export deployments
        deployments.push(Deployment("testAZTEC", address(testAztec)));
        deployments.push(Deployment("GuardianPause", address(guardianPause)));
        deployments.push(Deployment("MinimalVault", address(minimalVault)));
        deployments.push(Deployment("StakingStub", address(stakingStub)));
    }
}
