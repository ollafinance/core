// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";
import { AtomicProxyFactory } from "./AtomicProxyFactory.sol";

/// @title OllaVaultDeployer
/// @notice Deploys OllaVault implementation and proxy
contract OllaVaultDeployer is BaseDeployer {
    AtomicProxyFactory internal immutable _PROXY_FACTORY;

    constructor(AtomicProxyFactory proxyFactory_) {
        _PROXY_FACTORY = proxyFactory_;
    }

    /// @notice Deploy OllaVault implementation and proxy (initialized atomically)
    /// @param config The deployment configuration
    /// @param vaultImplementation The OllaVault implementation address
    /// @param asset The asset token address
    /// @param stAztec The StAztec token address
    /// @param withdrawalQueue The WithdrawalQueue proxy address
    /// @param core The OllaCore proxy address
    /// @param governance The OllaGovernance proxy address (set as owner)
    /// @param salt The deterministic salt used by AtomicProxyFactory
    /// @return implementation The OllaVault implementation address
    /// @return proxy The OllaVault proxy address
    function deploy(
        DeployConfig memory config,
        address vaultImplementation,
        address asset,
        address stAztec,
        address withdrawalQueue,
        address core,
        address governance,
        bytes32 salt
    ) external returns (address implementation, address proxy) {
        if (vaultImplementation == address(0)) {
            revert("OllaVaultDeployer: implementation required");
        }

        vm.startBroadcast(config.deployerPrivateKey);

        address vaultProxy = _PROXY_FACTORY.deployVaultAndInitialize(
            vaultImplementation, salt, IERC20(asset), IStAztec(stAztec), withdrawalQueue, core, governance
        );
        _logDeployment("OllaVault Proxy", vaultProxy);

        vm.stopBroadcast();

        return (vaultImplementation, vaultProxy);
    }

    function predictProxy(address implementation, bytes32 salt) external view returns (address) {
        return _PROXY_FACTORY.computeAddress(implementation, salt);
    }
}
