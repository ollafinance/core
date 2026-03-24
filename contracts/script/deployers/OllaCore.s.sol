// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";
import { AtomicProxyFactory } from "./AtomicProxyFactory.sol";

/// @title OllaCoreDeployer
/// @notice Deploys OllaCore implementation and proxy
contract OllaCoreDeployer is BaseDeployer {
    AtomicProxyFactory internal immutable _PROXY_FACTORY;

    constructor(AtomicProxyFactory proxyFactory_) {
        _PROXY_FACTORY = proxyFactory_;
    }

    /// @notice Deploy OllaCore implementation and proxy (initialized atomically)
    /// @param config The deployment configuration
    /// @param coreImplementation The OllaCore implementation address
    /// @param asset The asset token address (MockAztec or real)
    /// @param stAztec The StAztec token address
    /// @param stakingManager The staking manager address
    /// @param safetyModule The safety module address
    /// @param salt The deterministic salt used by AtomicProxyFactory
    /// @return implementation The OllaCore implementation address
    /// @return proxy The OllaCore proxy address
    function deploy(
        DeployConfig memory config,
        address coreImplementation,
        address asset,
        address stAztec,
        address stakingManager,
        address safetyModule,
        bytes32 salt
    ) external returns (address implementation, address proxy) {
        if (coreImplementation == address(0)) {
            revert("OllaCoreDeployer: implementation required");
        }

        vm.startBroadcast(config.deployerPrivateKey);

        address coreProxy = _PROXY_FACTORY.deployCoreAndInitialize(
            coreImplementation,
            salt,
            IERC20(asset),
            IStAztec(stAztec),
            IStakingManager(stakingManager),
            config.protocolFeeBP,
            config.treasuryFeeSplitBP,
            config.governance,
            IRewardsAccumulator(config.rewardsAccumulator),
            safetyModule
        );
        _logDeployment("OllaCore Proxy", coreProxy);

        vm.stopBroadcast();

        return (coreImplementation, coreProxy);
    }

    function predictProxy(address implementation, bytes32 salt) external view returns (address) {
        return _PROXY_FACTORY.computeAddress(implementation, salt);
    }
}
