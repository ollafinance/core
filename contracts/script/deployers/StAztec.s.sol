// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { StAztec } from "src/core/StAztec.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";

/// @title StAztecDeployer
/// @notice Deploys StAztec token linked to OllaCore
contract StAztecDeployer is BaseDeployer {
    /// @notice Deploy StAztec token
    /// @param config The deployment configuration
    /// @param ollaCoreProxy The OllaCore proxy address to link to
    /// @return stAztec The deployed StAztec address
    function deploy(DeployConfig memory config, address ollaCoreProxy) external returns (address stAztec) {
        require(ollaCoreProxy != address(0), "StAztecDeployer: OllaCore proxy address required");

        vm.startBroadcast(config.deployerPrivateKey);

        StAztec token = new StAztec(config.governance, ollaCoreProxy);
        _logDeployment("StAztec", address(token));

        vm.stopBroadcast();

        return address(token);
    }
}
