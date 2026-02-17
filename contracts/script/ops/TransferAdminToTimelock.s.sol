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

        address timelock =
            _addrOrDeployment("TIMELOCK", "TimelockController", "TIMELOCK missing: set TIMELOCK or deploy timelock");

        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing: set CORE or deploy local");
        address withdrawalQueue =
            _addrOrDeployment("WITHDRAWAL_QUEUE", "WithdrawalQueueProxy", "WithdrawalQueue missing");
        address rewardsVault = _addrOrDeployment("REWARDS_VAULT", "RewardsVaultProxy", "RewardsVault missing");
        address stakingManager = _addrOrDeployment("STAKING_MANAGER", "StakingManagerProxy", "StakingManager missing");
        address stakingProviderRegistry = _addrOrDeployment(
            "STAKING_PROVIDER_REGISTRY", "StakingProviderRegistryProxy", "StakingProviderRegistry missing"
        );
        address stAztec = _addrOrDeployment("STAZTEC", "StAztec", "StAztec missing");
        address safetyModule = _addrOrDeployment("SAFETY_MODULE", "SafetyModule", "SafetyModule missing");

        bytes32 adminRole = AccessControlUpgradeable.DEFAULT_ADMIN_ROLE();

        vm.startBroadcast(pk);

        _grantAndRevoke(core, adminRole, timelock, caller);
        _grantAndRevoke(withdrawalQueue, adminRole, timelock, caller);
        _grantAndRevoke(rewardsVault, adminRole, timelock, caller);
        _grantAndRevoke(stakingManager, adminRole, timelock, caller);
        _grantAndRevoke(stakingProviderRegistry, adminRole, timelock, caller);
        _grantAndRevoke(stAztec, adminRole, timelock, caller);
        _grantAndRevoke(safetyModule, adminRole, timelock, caller);

        vm.stopBroadcast();
    }

    function _grantAndRevoke(address target, bytes32 role, address timelock, address caller) internal {
        AccessControlUpgradeable(target).grantRole(role, timelock);
        AccessControlUpgradeable(target).revokeRole(role, caller);
    }
}
