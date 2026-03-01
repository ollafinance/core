// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { RewardsCollector } from "src/core/RewardsCollector.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";

/// @title RewardsCollectorDeployer
/// @notice Deploys RewardsCollector implementation and proxy.
contract RewardsCollectorDeployer is BaseDeployer {
    /// @notice Deploy RewardsCollector implementation + proxy (initialized atomically).
    /// @param config The deployment configuration.
    /// @param rewardsToken The rewards token (same as staking asset).
    /// @param core The OllaCore proxy address.
    /// @param admin The DEFAULT_ADMIN_ROLE address.
    /// @return implementation The RewardsCollector implementation address.
    /// @return proxy The RewardsCollector proxy address.
    function deploy(DeployConfig memory config, IERC20 rewardsToken, address core, address admin)
        external
        returns (address implementation, address proxy)
    {
        vm.startBroadcast(config.deployerPrivateKey);

        RewardsCollector vaultImpl = new RewardsCollector();
        _logDeployment("RewardsCollector Implementation", address(vaultImpl));

        bytes memory initData = abi.encodeCall(RewardsCollector.initialize, (rewardsToken, core, admin));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        _logDeployment("RewardsCollector Proxy", address(vaultProxy));

        vm.stopBroadcast();

        return (address(vaultImpl), address(vaultProxy));
    }
}
