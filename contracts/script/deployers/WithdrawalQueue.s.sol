// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";

/// @title WithdrawalQueueDeployer
/// @notice Deploys WithdrawalQueue implementation and proxy.
contract WithdrawalQueueDeployer is BaseDeployer {
    /// @notice Deploy WithdrawalQueue implementation + proxy (initialized atomically).
    /// @param config The deployment configuration.
    /// @param core The OllaCore proxy address.
    /// @param admin The DEFAULT_ADMIN_ROLE address.
    /// @param gasThreshold The initial gas threshold for finalize loop.
    /// @return implementation The WithdrawalQueue implementation address.
    /// @return proxy The WithdrawalQueue proxy address.
    function deploy(DeployConfig memory config, address core, address admin, uint256 gasThreshold)
        external
        returns (address implementation, address proxy)
    {
        vm.startBroadcast(config.deployerPrivateKey);

        WithdrawalQueue queueImpl = new WithdrawalQueue();
        _logDeployment("WithdrawalQueue Implementation", address(queueImpl));

        bytes memory initData = abi.encodeCall(WithdrawalQueue.initialize, (core, admin, gasThreshold));
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImpl), initData);
        _logDeployment("WithdrawalQueue Proxy", address(queueProxy));

        vm.stopBroadcast();

        return (address(queueImpl), address(queueProxy));
    }
}
