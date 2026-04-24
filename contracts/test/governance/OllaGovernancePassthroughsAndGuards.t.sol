// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { OllaGovernanceSetup } from "./OllaGovernanceSetup.t.sol";

/// @notice Minimal OllaVault V2 stub for satellite upgrade tests.
contract OllaVaultV2Mock is OllaVault {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @title OllaGovernancePassthroughsAndGuardsTest
/// @notice Tests covering untested branches and functions in OllaGovernance.sol.
contract OllaGovernancePassthroughsAndGuardsTest is OllaGovernanceSetup {
    /*//////////////////////////////////////////////////////////////
                    UNTESTED FUNCTIONS: recoverStAztec
    //////////////////////////////////////////////////////////////*/

    function test_RecoverStAztec_ViaTimelock() external {
        // Mint stAztec to the vault (vault is the minter of StAztec)
        uint256 recoverAmount = 5 ether;
        vm.prank(address(vault));
        stAztec.mint(address(vault), recoverAmount);

        uint256 aliceBalanceBefore = stAztec.balanceOf(alice);

        bytes memory data = abi.encodeCall(IOllaGovernance.recoverStAztec, (alice, recoverAmount));
        _scheduleAndExecute(address(gov), data);

        assertEq(stAztec.balanceOf(alice), aliceBalanceBefore + recoverAmount, "alice should receive recovered stAztec");
    }

    /*//////////////////////////////////////////////////////////////
                UNTESTED FUNCTIONS: reconcileBufferedAssets
    //////////////////////////////////////////////////////////////*/

    function test_ReconcileBufferedAssets_ViaTimelock() external {
        // Send extra asset tokens directly to vault to create a positive delta
        uint256 extraAmount = 10 ether;
        asset.mint(address(vault), extraAmount);

        uint256 bufferedBefore = vault.bufferedAssets();

        bytes memory data = abi.encodeCall(IOllaGovernance.reconcileBufferedAssets, ());
        _scheduleAndExecute(address(gov), data);

        assertEq(vault.bufferedAssets(), bufferedBefore + extraAmount, "buffered assets should absorb extra tokens");
    }

    /*//////////////////////////////////////////////////////////////
                    INITIALIZE ZERO-ADDRESS GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_InitializeZeroAdmin() external {
        OllaGovernance impl = new OllaGovernance();
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        vm.expectRevert(abi.encodeWithSelector(IOllaGovernance.OllaGovernance__ZeroAddress.selector, "admin"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(OllaGovernance.initialize, (1 days, proposers, executors, address(0), treasuryAddr))
        );
    }

    function test_RevertWhen_InitializeZeroTreasury() external {
        OllaGovernance impl = new OllaGovernance();
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        vm.expectRevert(abi.encodeWithSelector(IOllaGovernance.OllaGovernance__ZeroAddress.selector, "treasury"));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(OllaGovernance.initialize, (1 days, proposers, executors, admin, address(0)))
        );
    }

    function test_Initialize_RevokesExternalDefaultAdminRole() external view {
        assertFalse(gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), admin), "admin should not retain DEFAULT_ADMIN_ROLE");
        assertTrue(gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), address(gov)), "timelock should retain DEFAULT_ADMIN_ROLE");
    }

    /*//////////////////////////////////////////////////////////////
                          SET CORE GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetCoreZeroAddress() external {
        // Deploy a fresh governance that hasn't had setCore called
        OllaGovernance freshImpl = new OllaGovernance();
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        ERC1967Proxy freshProxy = new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(OllaGovernance.initialize, (1 days, proposers, executors, admin, treasuryAddr))
        );
        OllaGovernance freshGov = OllaGovernance(payable(address(freshProxy)));

        vm.expectRevert(abi.encodeWithSelector(IOllaGovernance.OllaGovernance__ZeroAddress.selector, "core"));
        vm.prank(address(freshGov));
        freshGov.setCore(address(0));
    }

    function test_RevertWhen_SetCore_DirectExternalAdminAfterInitialization() external {
        OllaGovernance freshImpl = new OllaGovernance();
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        ERC1967Proxy freshProxy = new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(OllaGovernance.initialize, (1 days, proposers, executors, admin, treasuryAddr))
        );
        OllaGovernance freshGov = OllaGovernance(payable(address(freshProxy)));

        vm.expectRevert();
        vm.prank(admin);
        freshGov.setCore(makeAddr("newCore"));
    }

    function test_RevertWhen_SetCoreAlreadySet() external {
        // In setUp, gov.setCore(address(core)) was already called
        vm.expectRevert(IOllaGovernance.OllaGovernance__CoreAlreadySet.selector);
        vm.prank(address(gov));
        gov.setCore(makeAddr("newCore"));
    }

    /*//////////////////////////////////////////////////////////////
                   UPGRADE SATELLITE HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_UpgradeSatellite_Vault_ViaTimelock() external {
        OllaVaultV2Mock newVaultImpl = new OllaVaultV2Mock();

        bytes memory data =
            abi.encodeCall(IOllaGovernance.upgradeSatellite, (address(vault), address(newVaultImpl), bytes("")));
        _scheduleAndExecute(address(gov), data);

        uint256 ver = OllaVaultV2Mock(address(vault)).version();
        assertEq(ver, 2, "vault should be upgraded to v2");
    }

    /*//////////////////////////////////////////////////////////////
              _authorizeUpgrade ZERO-ADDRESS GUARD
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SelfUpgradeZeroImplementation() external {
        // Schedule upgradeToAndCall(address(0), "") on governance itself
        bytes memory upgradeData = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(0), ""));

        vm.prank(admin);
        gov.schedule(address(gov), 0, upgradeData, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert();
        vm.prank(admin);
        gov.execute(address(gov), 0, upgradeData, bytes32(0), bytes32(0));
    }
}
