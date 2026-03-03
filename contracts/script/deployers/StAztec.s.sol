// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { StAztec } from "src/vault/StAztec.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";

/// @title StAztecDeployer
/// @notice Deploys StAztec token linked to OllaVault
contract StAztecDeployer is BaseDeployer {
    /// @notice Deploy StAztec token
    /// @param config The deployment configuration
    /// @param ollaVaultProxy The OllaVault proxy address authorized to mint/burn
    /// @return stAztec The deployed StAztec address
    function deploy(DeployConfig memory config, address ollaVaultProxy) external returns (address stAztec) {
        require(ollaVaultProxy != address(0), "StAztecDeployer: OllaVault proxy address required");

        vm.startBroadcast(config.deployerPrivateKey);

        StAztec token = new StAztec(ollaVaultProxy);
        _logDeployment("StAztec", address(token));

        vm.stopBroadcast();

        return address(token);
    }
}
