// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";

/// @title OllaGovernanceDeployer
/// @notice Deploys OllaGovernance implementation and proxy
contract OllaGovernanceDeployer is BaseDeployer {
    /// @notice Deploy OllaGovernance implementation and proxy (initialized).
    /// @param config The deployment configuration.
    /// @param treasury The initial treasury address.
    /// @return implementation The OllaGovernance implementation address.
    /// @return proxy The OllaGovernance proxy address.
    function deploy(DeployConfig memory config, address treasury)
        external
        returns (address implementation, address proxy)
    {
        vm.startBroadcast(config.deployerPrivateKey);

        // Deploy implementation
        OllaGovernance govImpl = new OllaGovernance();
        _logDeployment("OllaGovernance Implementation", address(govImpl));

        // Build proposer/executor arrays from config.governance
        // The governance address (e.g. multisig) holds proposer + executor + canceller roles.
        address[] memory proposers = new address[](1);
        proposers[0] = config.governance;
        address[] memory executors = new address[](1);
        executors[0] = config.governance;

        // Deploy proxy with initialization
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(
                OllaGovernance.initialize,
                (
                    config.timelockMinDelay,
                    proposers,
                    executors,
                    config.governance, // admin
                    treasury
                )
            )
        );
        _logDeployment("OllaGovernance Proxy", address(govProxy));

        vm.stopBroadcast();

        return (address(govImpl), address(govProxy));
    }

    /// @notice Wire OllaGovernance to OllaCore after both are deployed.
    /// @param config The deployment configuration.
    /// @param govProxy The OllaGovernance proxy address.
    /// @param coreProxy The OllaCore proxy address.
    function setCore(DeployConfig memory config, address govProxy, address coreProxy) external {
        vm.startBroadcast(config.deployerPrivateKey);
        OllaGovernance(payable(govProxy)).setCore(coreProxy);
        vm.stopBroadcast();
    }
}
