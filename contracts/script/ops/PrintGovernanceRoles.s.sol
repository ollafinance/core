// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

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
        _logCandidate(
            "deployment.deployer",
            _tryReadAddressFromDeployment(env, ".deployer"),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
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
            "address.OllaCoreProxy",
            _tryReadDeployment(env, "OllaCoreProxy"),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "address.OllaVaultProxy",
            _tryReadDeployment(env, "OllaVaultProxy"),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "address.StakingManagerProxy",
            _tryReadDeployment(env, "StakingManagerProxy"),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "address.StakingProviderRegistryProxy",
            _tryReadDeployment(env, "StakingProviderRegistryProxy"),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "address.RewardsAccumulatorProxy",
            _tryReadDeployment(env, "RewardsAccumulatorProxy"),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "address.WithdrawalQueueProxy",
            _tryReadDeployment(env, "WithdrawalQueueProxy"),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
        );
        _logCandidate(
            "address.SafetyModule",
            _tryReadDeployment(env, "SafetyModule"),
            gov,
            proposerRole,
            executorRole,
            cancellerRole,
            defaultAdminRole
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
}
