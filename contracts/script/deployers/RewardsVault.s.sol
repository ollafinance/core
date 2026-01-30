// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { BaseDeployer } from "../base/BaseDeployer.s.sol";
import { DeployConfig } from "../config/Config.s.sol";
import { RewardsVault } from "src/core/RewardsVault.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

/// @title RewardsVaultDeployer
/// @notice Deploys RewardsVault implementation and proxy.
contract RewardsVaultDeployer is BaseDeployer {
    /// @notice Deploy RewardsVault implementation + proxy (uninitialized).
    /// @param config The deployment configuration.
    /// @return implementation The RewardsVault implementation address.
    /// @return proxy The RewardsVault proxy address.
    function deploy(DeployConfig memory config) external returns (address implementation, address proxy) {
        vm.startBroadcast(config.deployerPrivateKey);

        RewardsVault vaultImpl = new RewardsVault();
        _logDeployment("RewardsVault Implementation", address(vaultImpl));

        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        _logDeployment("RewardsVault Proxy", address(vaultProxy));

        vm.stopBroadcast();

        return (address(vaultImpl), address(vaultProxy));
    }

    /// @notice Initialize RewardsVault proxy.
    /// @param config The deployment configuration.
    /// @param proxyAddress The RewardsVault proxy address.
    /// @param rewardsToken The rewards token (same as staking asset).
    /// @param core The OllaCore proxy address.
    /// @param admin The DEFAULT_ADMIN_ROLE address.
    function initialize(
        DeployConfig memory config,
        address proxyAddress,
        IERC20 rewardsToken,
        address core,
        address admin
    ) external {
        vm.startBroadcast(config.deployerPrivateKey);

        RewardsVault(proxyAddress).initialize(rewardsToken, core, admin);
        _logDeployment("RewardsVault initialized", proxyAddress);

        vm.stopBroadcast();
    }
}
