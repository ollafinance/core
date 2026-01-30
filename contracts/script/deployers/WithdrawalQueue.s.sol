// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { BaseDeployer } from "../base/BaseDeployer.s.sol";
import { DeployConfig } from "../config/Config.s.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

/// @title WithdrawalQueueDeployer
/// @notice Deploys WithdrawalQueue implementation and proxy.
contract WithdrawalQueueDeployer is BaseDeployer {
    /// @notice Deploy WithdrawalQueue implementation + proxy (uninitialized).
    /// @param config The deployment configuration.
    /// @return implementation The WithdrawalQueue implementation address.
    /// @return proxy The WithdrawalQueue proxy address.
    function deploy(DeployConfig memory config) external returns (address implementation, address proxy) {
        vm.startBroadcast(config.deployerPrivateKey);

        WithdrawalQueue queueImpl = new WithdrawalQueue();
        _logDeployment("WithdrawalQueue Implementation", address(queueImpl));

        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImpl), "");
        _logDeployment("WithdrawalQueue Proxy", address(queueProxy));

        vm.stopBroadcast();

        return (address(queueImpl), address(queueProxy));
    }

    /// @notice Initialize WithdrawalQueue proxy.
    /// @param config The deployment configuration.
    /// @param proxyAddress The WithdrawalQueue proxy address.
    /// @param core The OllaCore proxy address.
    /// @param admin The DEFAULT_ADMIN_ROLE address.
    function initialize(DeployConfig memory config, address proxyAddress, address core, address admin) external {
        vm.startBroadcast(config.deployerPrivateKey);

        WithdrawalQueue(proxyAddress).initialize(core, admin);
        _logDeployment("WithdrawalQueue initialized", proxyAddress);

        vm.stopBroadcast();
    }
}
