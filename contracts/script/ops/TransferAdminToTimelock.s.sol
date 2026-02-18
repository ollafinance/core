// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";

import { BaseScript } from "../base/BaseScript.s.sol";

/// @title TransferAdminToTimelock
/// @notice Grants DEFAULT_ADMIN_ROLE to timelock and revokes it from the caller.
contract TransferAdminToTimelock is BaseScript {
    function run() external {
        uint256 pk = _privateKey();
        address caller = vm.addr(pk);

        address timelock = vm.envOr("TIMELOCK", address(0));
        if (timelock == address(0)) {
            timelock = _addrOrDeployment(
                "TIMELOCK", "TimelockController", "TIMELOCK missing: set TIMELOCK or deploy timelock"
            );
        }

        address core = _addrFromEnvOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        address withdrawalQueue =
            _addrFromEnvOrDeployment("WITHDRAWAL_QUEUE", "WithdrawalQueueProxy", "WithdrawalQueue missing");
        address rewardsVault = _addrFromEnvOrDeployment("REWARDS_VAULT", "RewardsVaultProxy", "RewardsVault missing");
        address stakingManager =
            _addrFromEnvOrDeployment("STAKING_MANAGER", "StakingManagerProxy", "StakingManager missing");
        address stakingProviderRegistry = _addrFromEnvOrDeployment(
            "STAKING_PROVIDER_REGISTRY", "StakingProviderRegistryProxy", "StakingProviderRegistry missing"
        );
        address stAztec = _addrFromEnvOrDeployment("STAZTEC", "StAztec", "StAztec missing");
        address safetyModule = _addrFromEnvOrDeployment("SAFETY_MODULE", "SafetyModule", "SafetyModule missing");

        bytes32 adminRole = bytes32(0);

        vm.startBroadcast(pk);

        _grantAndRevoke(core, adminRole, timelock, caller);
        _grantAndRevoke(withdrawalQueue, adminRole, timelock, caller);
        _grantAndRevoke(rewardsVault, adminRole, timelock, caller);
        _grantAndRevoke(stakingManager, adminRole, timelock, caller);
        _grantAndRevoke(stakingProviderRegistry, adminRole, timelock, caller);
        _grantAndRevoke(stAztec, adminRole, timelock, caller);
        if (_boolOr("SKIP_SAFETY_MODULE", false)) {
            _logDeployment("Skip SafetyModule migration", safetyModule);
        } else if (_supportsAccessControl(safetyModule, adminRole)) {
            _grantAndRevoke(safetyModule, adminRole, timelock, caller);
        } else {
            revert("TransferAdminToTimelock: SafetyModule lacks AccessControl");
        }

        vm.stopBroadcast();
    }

    function _grantAndRevoke(address target, bytes32 role, address timelock, address caller) internal {
        AccessControlUpgradeable(target).grantRole(role, timelock);
        AccessControlUpgradeable(target).revokeRole(role, caller);
    }

    function _supportsAccessControl(address target, bytes32 role) internal view returns (bool) {
        try AccessControlUpgradeable(target).hasRole(role, address(0)) returns (bool) {
            return true;
        } catch {
            return false;
        }
    }

    function _addrFromEnvOrDeployment(string memory envKey, string memory deploymentKey, string memory errorMessage)
        internal
        view
        returns (address)
    {
        address fromEnv = vm.envOr(envKey, address(0));
        if (fromEnv != address(0)) {
            return fromEnv;
        }

        return _addrOrDeployment(envKey, deploymentKey, errorMessage);
    }
}
