// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { BaseDeployer, console2 } from "../base/BaseDeployer.s.sol";
import { DeployConfig } from "../config/Config.s.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IStAztec } from "src/core/interfaces/IStAztec.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

/// @title OllaCoreDeployer
/// @notice Deploys OllaCore implementation and proxy
contract OllaCoreDeployer is BaseDeployer {
    /// @notice Deploy OllaCore implementation and proxy (uninitialized)
    /// @param config The deployment configuration
    /// @return implementation The OllaCore implementation address
    /// @return proxy The OllaCore proxy address
    function deploy(DeployConfig memory config) external returns (address implementation, address proxy) {
        vm.startBroadcast(config.deployerPrivateKey);

        // Deploy implementation
        OllaCore coreImpl = new OllaCore();
        _logDeployment("OllaCore Implementation", address(coreImpl));

        // Deploy proxy (uninitialized - empty bytes so initialize is NOT called yet)
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), "");
        _logDeployment("OllaCore Proxy", address(coreProxy));

        vm.stopBroadcast();

        return (address(coreImpl), address(coreProxy));
    }

    /// @notice Initialize OllaCore proxy with all dependencies
    /// @param config The deployment configuration
    /// @param proxyAddress The OllaCore proxy address
    /// @param asset The asset token address (MockAztec or real)
    /// @param stAztec The StAztec token address
    /// @param stakingManager The staking manager address
    function initialize(
        DeployConfig memory config,
        address proxyAddress,
        address asset,
        address stAztec,
        address stakingManager
    ) external {
        vm.startBroadcast(config.deployerPrivateKey);

        OllaCore(proxyAddress)
            .initialize(
                IERC20(asset),
                IStAztec(stAztec),
                IStakingManager(stakingManager),
                config.protocolFeeBP,
                config.treasuryFeeSplitBP,
                config.governance,
                config.withdrawalQueue,
                config.rewardsVault,
                config.safetyModule
            );
        console2.log("OllaCore initialized");

        // Approve core to spend deployer's tokens (for local dev convenience)
        if (config.deployMocks) {
            IERC20(asset).approve(proxyAddress, type(uint256).max);
            console2.log("Approved OllaCore to spend deployer's tokens");
        }

        vm.stopBroadcast();
    }
}
