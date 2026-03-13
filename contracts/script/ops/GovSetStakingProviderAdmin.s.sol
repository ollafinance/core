// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;
import { console2 } from "@forge-std/console2.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { GovActionBase } from "./GovActionBase.s.sol";

/// @title GovSetStakingProviderAdmin
/// @notice Grants STAKING_PROVIDER_ADMIN_ROLE to NEW_PROVIDER_ADMIN via governance timelock.
/// @dev Optionally revokes the role from OLD_PROVIDER_ADMIN when provided.
contract GovSetStakingProviderAdmin is GovActionBase {
    function run() external {
        address governance = _governanceAddress();
        address registry = _addrOrDeployment(
            "STAKING_PROVIDER_REGISTRY", "StakingProviderRegistryProxy", "STAKING_PROVIDER_REGISTRY missing"
        );
        address newProviderAdmin = vm.envAddress("NEW_PROVIDER_ADMIN");
        address oldProviderAdmin = vm.envOr("OLD_PROVIDER_ADMIN", address(0));
        bytes32 role = StakingProviderRegistry(registry).STAKING_PROVIDER_ADMIN_ROLE();
        console2.log("governance", governance);
        console2.log("stakingProviderRegistry", registry);
        console2.logBytes32(role);
        console2.log("newProviderAdmin", newProviderAdmin);
        console2.log("oldProviderAdmin", oldProviderAdmin);
        console2.log("hasRole(newProviderAdmin) before", IAccessControl(registry).hasRole(role, newProviderAdmin));
        if (!IAccessControl(registry).hasRole(role, newProviderAdmin)) {
            bytes memory grantData = abi.encodeCall(IAccessControl.grantRole, (role, newProviderAdmin));
            _runTimelockAction(governance, registry, grantData);
        } else {
            console2.log("newProviderAdmin already has role");
        }
        if (oldProviderAdmin != address(0) && oldProviderAdmin != newProviderAdmin) {
            console2.log("hasRole(oldProviderAdmin) before", IAccessControl(registry).hasRole(role, oldProviderAdmin));
            if (IAccessControl(registry).hasRole(role, oldProviderAdmin)) {
                bytes memory revokeData = abi.encodeCall(IAccessControl.revokeRole, (role, oldProviderAdmin));
                _runTimelockAction(governance, registry, revokeData);
            } else {
                console2.log("oldProviderAdmin does not have role, skip revoke");
            }
        }
        console2.log("hasRole(newProviderAdmin) after", IAccessControl(registry).hasRole(role, newProviderAdmin));
        if (oldProviderAdmin != address(0) && oldProviderAdmin != newProviderAdmin) {
            console2.log("hasRole(oldProviderAdmin) after", IAccessControl(registry).hasRole(role, oldProviderAdmin));
        }
    }
}
