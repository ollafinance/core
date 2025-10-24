// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Aztlan Labs

pragma solidity ^0.8.19;

import "../src/testAZTEC.sol";
import "./DeployHelpers.s.sol";

contract DeploytestAZTEC is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        testAZTEC testAztec = new testAZTEC();
        console.logString(string.concat("testAZTEC deployed at: ", vm.toString(address(testAztec))));
    }
}
