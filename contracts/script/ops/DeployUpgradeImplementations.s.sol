// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { VmSafe } from "@forge-std/Vm.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { RewardsAccumulator } from "src/core/RewardsAccumulator.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title DeployUpgradeImplementations
/// @notice Deploys new implementation contracts for all upgradeable proxies and writes addresses
///         to the deployment artifact. Run with --broadcast to deploy on-chain.
/// @dev After running, use PrintNextProtocolUpgradePayload.s.sol to generate timelock payloads.
contract DeployUpgradeImplementations is BaseScript {
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        string memory env = _deployEnv();

        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            console2.log("env", env);
            console2.log("chainId", block.chainid);
            console2.log("next.action", "blocked_requires_broadcast");
            console2.log("next.step", "Run with --broadcast and PRIVATE_KEY to deploy implementations on-chain.");
            return;
        }

        uint256 pk = _privateKey();

        // Read current proxy implementations for comparison
        address queueProxy =
            _addrOrDeployment("WITHDRAWAL_QUEUE_PROXY", "WithdrawalQueueProxy", "WITHDRAWAL_QUEUE_PROXY missing");
        address rewardsProxy = _addrOrDeployment(
            "REWARDS_ACCUMULATOR_PROXY", "RewardsAccumulatorProxy", "REWARDS_ACCUMULATOR_PROXY missing"
        );
        address sprProxy = _addrOrDeployment(
            "STAKING_PROVIDER_REGISTRY_PROXY", "StakingProviderRegistryProxy", "STAKING_PROVIDER_REGISTRY_PROXY missing"
        );
        address stakingManagerProxy =
            _addrOrDeployment("STAKING_MANAGER_PROXY", "StakingManagerProxy", "STAKING_MANAGER_PROXY missing");
        address vaultProxy = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");
        address coreProxy = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");
        address governanceProxy =
            _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");

        console2.log("env", env);
        console2.log("chainId", block.chainid);
        console2.log("deployer", vm.addr(pk));
        console2.log("");
        console2.log("=== Deploying new implementation contracts ===");
        console2.log("");

        vm.startBroadcast(pk);

        address withdrawalQueueImpl = address(new WithdrawalQueue());
        address rewardsAccumulatorImpl = address(new RewardsAccumulator());
        address sprImpl = address(new StakingProviderRegistry());
        address stakingManagerImpl = address(new StakingManager());
        address vaultImpl = address(new OllaVault());
        address coreImpl = address(new OllaCore());
        address governanceImpl = address(new OllaGovernance());

        vm.stopBroadcast();

        // Log deployed addresses and whether they differ from current
        _logDeployment("WithdrawalQueue", withdrawalQueueImpl, _proxyImpl(queueProxy));
        _logDeployment("RewardsAccumulator", rewardsAccumulatorImpl, _proxyImpl(rewardsProxy));
        _logDeployment("StakingProviderRegistry", sprImpl, _proxyImpl(sprProxy));
        _logDeployment("StakingManager", stakingManagerImpl, _proxyImpl(stakingManagerProxy));
        _logDeployment("OllaVault", vaultImpl, _proxyImpl(vaultProxy));
        _logDeployment("OllaCore", coreImpl, _proxyImpl(coreProxy));
        _logDeployment("OllaGovernance", governanceImpl, _proxyImpl(governanceProxy));

        // Write to deployment artifact
        _setDeploymentAddress(env, "WithdrawalQueueImplementation", withdrawalQueueImpl);
        _setDeploymentAddress(env, "RewardsAccumulatorImplementation", rewardsAccumulatorImpl);
        _setDeploymentAddress(env, "StakingProviderRegistryImplementation", sprImpl);
        _setDeploymentAddress(env, "StakingManagerImplementation", stakingManagerImpl);
        _setDeploymentAddress(env, "OllaVaultImplementation", vaultImpl);
        _setDeploymentAddress(env, "OllaCoreImplementation", coreImpl);
        _setDeploymentAddress(env, "OllaGovernanceImplementation", governanceImpl);

        console2.log("");
        console2.log("=== Deployment artifact updated ===");
        console2.log("next.step", "Run PrintNextProtocolUpgradePayload to generate the first timelock payload.");
    }

    function _proxyImpl(address proxy) internal view returns (address impl) {
        bytes32 value = vm.load(proxy, _IMPLEMENTATION_SLOT);
        impl = address(uint160(uint256(value)));
        return impl;
    }

    function _logDeployment(string memory label, address newImpl, address currentImpl) internal view {
        bool codeChanged = _codeDiffers(newImpl, currentImpl);
        console2.log(string.concat(label, ".newImplementation"), newImpl);
        console2.log(string.concat(label, ".currentImplementation"), currentImpl);
        console2.log(string.concat(label, ".codeChanged"), codeChanged);
        console2.log("");
    }

    function _codeDiffers(address a, address b) internal view returns (bool) {
        if (a == b) return false;
        if (a.code.length == 0 || b.code.length == 0) return true;
        return a.codehash != b.codehash;
    }
}
