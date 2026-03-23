// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { RolesLib } from "src/shared/RolesLib.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { BaseScript } from "./../base/BaseScript.s.sol";

/// @title PrintGovernanceRoles
/// @notice Prints governance timelock role status for key addresses and optional candidates.
/// @dev Optional strict mode: set REQUIRE_CALLER_GOV_ROLE=true to revert unless caller can schedule+execute.
contract PrintGovernanceRoles is BaseScript {
    function run() external view {
        string memory env = _deployEnv();
        address governance = _addrOrDeployment("GOVERNANCE_PROXY", "OllaGovernanceProxy", "GOVERNANCE_PROXY missing");

        OllaGovernance gov = OllaGovernance(payable(governance));
        bytes32 proposerRole = gov.PROPOSER_ROLE();
        bytes32 executorRole = gov.EXECUTOR_ROLE();
        bytes32 cancellerRole = gov.CANCELLER_ROLE();
        bytes32 defaultAdminRole = gov.DEFAULT_ADMIN_ROLE();

        console2.log("env", env);
        console2.log("governance", governance);
        console2.log("minDelay", gov.getMinDelay());
        console2.log("governanceAdmin", gov.governanceAdmin());
        console2.log("proposerRole");
        console2.logBytes32(proposerRole);
        console2.log("executorRole");
        console2.logBytes32(executorRole);
        console2.log("cancellerRole");
        console2.logBytes32(cancellerRole);
        console2.log("defaultAdminRole");
        console2.logBytes32(defaultAdminRole);

        // Open role checks (address(0) wildcard)
        bool proposerOpen = gov.hasRole(proposerRole, address(0));
        bool executorOpen = gov.hasRole(executorRole, address(0));
        bool cancellerOpen = gov.hasRole(cancellerRole, address(0));
        console2.log("open.proposer(address(0))", proposerOpen);
        console2.log("open.executor(address(0))", executorOpen);
        console2.log("open.canceller(address(0))", cancellerOpen);

        address caller = address(0);
        bool hasPk = vm.envExists("PRIVATE_KEY");
        if (hasPk) {
            caller = vm.addr(vm.envUint("PRIVATE_KEY"));
            _logCandidate(
                "caller(PRIVATE_KEY)", caller, gov, proposerRole, executorRole, cancellerRole, defaultAdminRole
            );

            bool callerCanSchedule = gov.hasRole(proposerRole, caller);
            bool callerCanExecute = gov.hasRole(executorRole, caller) || executorOpen;
            console2.log("caller.canSchedule", callerCanSchedule);
            console2.log("caller.canExecute", callerCanExecute);
            console2.log("caller.canScheduleAndExecute", callerCanSchedule && callerCanExecute);

            if (vm.envOr("REQUIRE_CALLER_GOV_ROLE", false)) {
                require(callerCanSchedule && callerCanExecute, "PrintGovernanceRoles: caller lacks proposer/executor");
            }
        } else {
            console2.log("PRIVATE_KEY not set; caller checks skipped");
        }

        // Known deployment addresses
        address deployer = _tryReadAddressFromDeployment(env, ".deployer");
        address coreProxy = _tryReadDeployment(env, "OllaCoreProxy");
        address vaultProxy = _tryReadDeployment(env, "OllaVaultProxy");
        address stakingManagerProxy = _tryReadDeployment(env, "StakingManagerProxy");
        address stakingProviderRegistryProxy = _tryReadDeployment(env, "StakingProviderRegistryProxy");
        address rewardsAccumulatorProxy = _tryReadDeployment(env, "RewardsAccumulatorProxy");
        address withdrawalQueueProxy = _tryReadDeployment(env, "WithdrawalQueueProxy");
        address safetyModule = _tryReadDeployment(env, "SafetyModule");

        _logCandidate("deployment.deployer", deployer, gov, proposerRole, executorRole, cancellerRole, defaultAdminRole);
        _logCandidate(
            "address.OllaGovernanceProxy",
            _tryReadDeployment(env, "OllaGovernanceProxy"),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "address.OllaCoreProxy", coreProxy, gov, proposerRole, executorRole, cancellerRole, defaultAdminRole
        );
        _logCandidate(
            "address.OllaVaultProxy", vaultProxy, gov, proposerRole, executorRole, cancellerRole, defaultAdminRole
        );
        _logCandidate(
            "address.StakingManagerProxy",
            stakingManagerProxy,
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logStakingManagerRewardsAccumulator(stakingManagerProxy, rewardsAccumulatorProxy);
        _logCandidate(
            "address.StakingProviderRegistryProxy",
            stakingProviderRegistryProxy,
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        address stakingProviderRegistry = _tryReadDeployment(env, "StakingProviderRegistry");
        if (stakingProviderRegistry == address(0)) {
            stakingProviderRegistry = stakingProviderRegistryProxy;
        }
        _logCandidate(
            "address.StakingProviderRegistry",
            stakingProviderRegistry,
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logStakingProviderAdmin(stakingProviderRegistry);
        _logCandidate(
            "address.RewardsAccumulatorProxy",
            rewardsAccumulatorProxy,
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "address.WithdrawalQueueProxy",
            withdrawalQueueProxy,
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "address.SafetyModule", safetyModule, gov, proposerRole, executorRole, cancellerRole, defaultAdminRole
        );

        _logGuardianRoleAssignments(
            coreProxy, vaultProxy, safetyModule, governance, deployer, caller, vm.envOr("GUARDIAN", address(0))
        );

        // Optional manual candidates
        _logCandidate(
            "candidate1",
            vm.envOr("CANDIDATE_1", address(0)),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "candidate2",
            vm.envOr("CANDIDATE_2", address(0)),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "candidate3",
            vm.envOr("CANDIDATE_3", address(0)),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
    }

    function _tryReadAddressFromDeployment(string memory env, string memory jsonPath) internal view returns (address) {
        string memory path = _getDeploymentPath(env);
        if (!vm.isFile(path)) return address(0);
        try vm.parseJsonAddress(vm.readFile(path), jsonPath) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }

    function _logCandidate(
        string memory label,
        address candidate,
        OllaGovernance gov,
        bytes32 proposerRole,
        bytes32 executorRole,
        bytes32 cancellerRole,
        bytes32 defaultAdminRole
    ) internal view {
        if (candidate == address(0)) {
            console2.log(label, address(0));
            return;
        }

        bool proposer = gov.hasRole(proposerRole, candidate);
        bool executor = gov.hasRole(executorRole, candidate);
        bool canceller = gov.hasRole(cancellerRole, candidate);
        bool defaultAdmin = gov.hasRole(defaultAdminRole, candidate);

        console2.log(label, candidate);
        console2.log("  proposer", proposer);
        console2.log("  executor", executor);
        console2.log("  canceller", canceller);
        console2.log("  defaultAdmin", defaultAdmin);
    }

    function _logStakingProviderAdmin(address stakingProviderRegistry) internal view {
        if (stakingProviderRegistry == address(0)) {
            console2.log("stakingProviderAdminRole.registry", address(0));
            return;
        }

        if (stakingProviderRegistry.code.length == 0) {
            console2.log("stakingProviderAdminRole.registry", stakingProviderRegistry);
            console2.log("stakingProviderAdminRole.error", "no code at registry");
            return;
        }

        bytes32 stakingProviderAdminRole = RolesLib.STAKING_PROVIDER_ADMIN_ROLE;

        console2.log("stakingProviderAdminRole.registry", stakingProviderRegistry);
        console2.log("stakingProviderAdminRole");
        console2.logBytes32(stakingProviderAdminRole);
        console2.log("stakingProviderAdminRole.note", "admin is managed via AccessControl role, not ProviderConfig");
    }

    function _logGuardianRoleAssignments(
        address core,
        address vault,
        address safetyModule,
        address governance,
        address deployer,
        address caller,
        address configuredGuardian
    ) internal view {
        bytes32 guardianRole = RolesLib.GUARDIAN_ROLE;
        console2.log("guardianRole");
        console2.logBytes32(guardianRole);

        _logAccessControlRoleMembership("guardian.core.governance", core, guardianRole, governance);
        _logAccessControlRoleMembership("guardian.vault.governance", vault, guardianRole, governance);
        _logAccessControlRoleMembership("guardian.safetyModule.governance", safetyModule, guardianRole, governance);
        _logAccessControlRoleMembership("guardian.safetyModule.deployer", safetyModule, guardianRole, deployer);
        _logAccessControlRoleMembership("guardian.safetyModule.caller", safetyModule, guardianRole, caller);
        _logAccessControlRoleMembership(
            "guardian.safetyModule.GUARDIAN(env)", safetyModule, guardianRole, configuredGuardian
        );
    }

    function _logStakingManagerRewardsAccumulator(address stakingManager, address deploymentRewardsAccumulator)
        internal
        view
    {
        if (stakingManager == address(0)) {
            console2.log("stakingManager.rewardsAccumulator", address(0));
            return;
        }

        // If the address has no code, treat as unset and avoid reverting.
        if (stakingManager.code.length == 0) {
            console2.log("stakingManager.rewardsAccumulator", address(0));
            if (deploymentRewardsAccumulator != address(0)) {
                console2.log("stakingManager.rewardsAccumulator.matchesDeployment", false);
            }
            return;
        }

        address configuredRewardsAccumulator;
        // Wrap in try/catch to gracefully handle unexpected implementations.
        try StakingManager(stakingManager).rewardsAccumulator() returns (address _configuredRewardsAccumulator) {
            configuredRewardsAccumulator = _configuredRewardsAccumulator;
        } catch {
            configuredRewardsAccumulator = address(0);
        }

        console2.log("stakingManager.rewardsAccumulator", configuredRewardsAccumulator);

        if (deploymentRewardsAccumulator != address(0)) {
            console2.log(
                "stakingManager.rewardsAccumulator.matchesDeployment",
                configuredRewardsAccumulator == deploymentRewardsAccumulator
            );
        }
    }

    function _logAccessControlRoleMembership(string memory label, address target, bytes32 role, address member)
        internal
        view
    {
        if (target == address(0) || member == address(0)) {
            console2.log(label, false);
            return;
        }

        // If the target has no code, it cannot implement IAccessControl; report false.
        if (target.code.length == 0) {
            console2.log(label, false);
            return;
        }

        bool hasRoleResult;
        // Use try/catch so that unexpected reverts degrade to "false" instead of halting the script.
        try IAccessControl(target).hasRole(role, member) returns (bool _hasRole) {
            hasRoleResult = _hasRole;
        } catch {
            hasRoleResult = false;
        }

        console2.log(label, hasRoleResult);
    }
}
