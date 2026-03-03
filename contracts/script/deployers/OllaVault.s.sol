// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";

/// @title OllaVaultDeployer
/// @notice Deploys OllaVault implementation and proxy
contract OllaVaultDeployer is BaseDeployer {
    /// @notice Deploy OllaVault implementation and proxy (uninitialized)
    /// @param config The deployment configuration
    /// @return implementation The OllaVault implementation address
    /// @return proxy The OllaVault proxy address
    function deploy(DeployConfig memory config) external returns (address implementation, address proxy) {
        vm.startBroadcast(config.deployerPrivateKey);

        // Deploy implementation
        OllaVault vaultImpl = new OllaVault();
        _logDeployment("OllaVault Implementation", address(vaultImpl));

        // Deploy proxy (uninitialized - empty bytes so initialize is NOT called yet)
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        _logDeployment("OllaVault Proxy", address(vaultProxy));

        vm.stopBroadcast();

        return (address(vaultImpl), address(vaultProxy));
    }

    /// @notice Initialize OllaVault proxy with all dependencies
    /// @param config The deployment configuration
    /// @param proxyAddress The OllaVault proxy address
    /// @param asset The asset token address
    /// @param stAztec The StAztec token address
    /// @param withdrawalQueue The WithdrawalQueue proxy address
    /// @param core The OllaCore proxy address
    /// @param governance The OllaGovernance proxy address (set as owner)
    function initialize(
        DeployConfig memory config,
        address proxyAddress,
        address asset,
        address stAztec,
        address withdrawalQueue,
        address core,
        address governance
    ) external {
        vm.startBroadcast(config.deployerPrivateKey);

        OllaVault(proxyAddress).initialize(IERC20(asset), IStAztec(stAztec), withdrawalQueue, core, governance);

        if (config.deployMocks) {
            IERC20(asset).approve(proxyAddress, type(uint256).max);
            IERC20(stAztec).approve(proxyAddress, type(uint256).max);
        }

        vm.stopBroadcast();
    }
}
