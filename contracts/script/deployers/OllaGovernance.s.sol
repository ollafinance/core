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

        // Build proposer/executor arrays.
        // config.governance (e.g. multisig) holds proposer + executor + canceller roles permanently.
        // config.deployer is added temporarily so it can schedule+execute wiring calls
        // (setVault, unpause) during deployment. These roles are revoked in renounceDeployerRoles().
        address[] memory proposers = new address[](2);
        proposers[0] = config.governance;
        proposers[1] = config.deployer;
        address[] memory executors = new address[](2);
        executors[0] = config.governance;
        executors[1] = config.deployer;

        // Deploy proxy with initialization
        // The deployer is granted DEFAULT_ADMIN_ROLE for initial wiring (setCore).
        // It MUST be renounced after setup via renounceDeployerRoles().
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(
                OllaGovernance.initialize,
                (
                    config.timelockMinDelay,
                    proposers,
                    executors,
                    config.deployer, // temporary admin for wiring
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

    /// @notice Renounce all temporary deployer roles after wiring is complete.
    /// @dev MUST be called after setCore and all timelock wiring (setVault, unpause).
    ///      Revokes PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE and DEFAULT_ADMIN_ROLE.
    ///      After this, only config.governance holds operational roles and the timelock
    ///      itself retains DEFAULT_ADMIN_ROLE.
    /// @param config The deployment configuration.
    /// @param govProxy The OllaGovernance proxy address.
    function renounceDeployerRoles(DeployConfig memory config, address govProxy) external {
        if (config.deployer == config.governance) {
            return;
        }
        OllaGovernance gov = OllaGovernance(payable(govProxy));
        vm.startBroadcast(config.deployerPrivateKey);
        // Revoke operational roles granted during initialization
        gov.renounceRole(gov.PROPOSER_ROLE(), config.deployer);
        gov.renounceRole(gov.EXECUTOR_ROLE(), config.deployer);
        gov.renounceRole(gov.CANCELLER_ROLE(), config.deployer);
        // Revoke temporary admin role
        gov.renounceRole(gov.DEFAULT_ADMIN_ROLE(), config.deployer);
        vm.stopBroadcast();
    }
}
