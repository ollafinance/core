// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerInitializeTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                           INITIALIZE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsConfig() external view {
        assertEq(address(stakingManager.stakingAsset()), address(aztec));
        assertEq(address(stakingManager.rollupRegistry()), address(rollupRegistry));
        assertEq(address(stakingManager.rewardsVault()), address(rewardsVault));
        assertEq(stakingManager.core(), core);
    }

    function test_Initialize_SetsProviderConfig() external view {
        IStakingManager.ProviderConfig memory config = stakingManager.getProviderConfig();
        assertEq(config.admin, providerAdmin);
        assertEq(config.rewardsRecipient, providerAdmin);
    }

    function test_Initialize_GrantsRoles() external view {
        assertTrue(stakingManager.hasRole(stakingManager.DEFAULT_ADMIN_ROLE(), defaultAdmin));
        assertTrue(
            stakingProviderRegistry.hasRole(stakingProviderRegistry.STAKING_PROVIDER_ADMIN_ROLE(), providerAdmin)
        );
        assertTrue(
            stakingProviderRegistry.hasRole(stakingProviderRegistry.STAKING_PROVIDER_ADMIN_ROLE(), providerAdmin)
        );
    }

    function test_Initialize_EmitsProviderSet() external {
        StakingManager implementation = new StakingManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        StakingManager mgr = StakingManager(address(proxy));

        StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
        StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));

        vm.expectEmit(true, true, true, true, address(registry));
        emit ProviderSet(providerAdmin, providerAdmin);

        registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);

        mgr.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsVault),
            core,
            address(registry),
            defaultAdmin
        );
    }

    function test_RevertWhen_InitializeZeroAddress() external {
        StakingManager implementation = new StakingManager();

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "stakingAsset")
            );
            mgr.initialize(
                IERC20(address(0)),
                address(rollupRegistry),
                address(rewardsVault),
                core,
                address(registry),
                defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "rollupRegistry")
            );
            mgr.initialize(
                IERC20(address(aztec)), address(0), address(rewardsVault), core, address(registry), defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "rewardsVault")
            );
            mgr.initialize(
                IERC20(address(aztec)), address(rollupRegistry), address(0), core, address(registry), defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "core"));
            mgr.initialize(
                IERC20(address(aztec)),
                address(rollupRegistry),
                address(rewardsVault),
                address(0),
                address(registry),
                defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "stakingProviderRegistry")
            );
            mgr.initialize(
                IERC20(address(aztec)), address(rollupRegistry), address(rewardsVault), core, address(0), defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "defaultAdmin")
            );
            mgr.initialize(
                IERC20(address(aztec)),
                address(rollupRegistry),
                address(rewardsVault),
                core,
                address(registry),
                address(0)
            );
        }
    }
}
