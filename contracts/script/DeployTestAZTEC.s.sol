// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Aztlan Labs

pragma solidity ^0.8.19;

import "../src/mocks/TestAZTEC.sol";
import "./DeployHelpers.s.sol";

contract DeployTestAZTEC is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        TestAZTEC testAztec = new TestAZTEC();
        console.logString(string.concat("TestAZTEC deployed at: ", vm.toString(address(testAztec))));
    }
}
