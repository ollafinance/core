// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { OllaGovernanceSetup } from "./OllaGovernanceSetup.t.sol";

/// @notice Minimal V2 stub for upgrade tests.
contract OllaCoreV2Mock is OllaCore {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Minimal V2 governance stub for self-upgrade tests.
contract OllaGovernanceV2Mock is OllaGovernance {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @title OllaGovernanceUpgradesTest
/// @notice Tests for upgrade authorization through OllaGovernance.
contract OllaGovernanceUpgradesTest is OllaGovernanceSetup {
    /*//////////////////////////////////////////////////////////////
                          UPGRADE CORE
    //////////////////////////////////////////////////////////////*/

    function test_UpgradeCore_ViaTimelock() external {
        OllaCoreV2Mock newImpl = new OllaCoreV2Mock();
        bytes memory data = abi.encodeCall(IOllaGovernance.upgradeCore, (address(newImpl)));

        _scheduleAndExecute(address(gov), data);

        uint256 ver = OllaCoreV2Mock(address(core)).version();
        assertEq(ver, 2, "core upgraded to v2");
    }

    function test_RevertWhen_UpgradeCore_DirectCall() external {
        OllaCoreV2Mock newImpl = new OllaCoreV2Mock();
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.upgradeCore(address(newImpl));
    }

    function test_RevertWhen_UpgradeCore_ZeroImplementation() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.upgradeCore, (address(0)));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert();
        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));
    }

    function test_UpgradeCore_PreservesState() external {
        // Deposit first
        uint256 depositAmount = 10 * DECIMALS;
        asset.mint(alice, depositAmount);
        vm.prank(alice);
        asset.approve(address(vault), depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount, alice, 0);

        uint256 totalBefore = core.totalAssets();

        // Upgrade
        OllaCoreV2Mock newImpl = new OllaCoreV2Mock();
        bytes memory data = abi.encodeCall(IOllaGovernance.upgradeCore, (address(newImpl)));
        _scheduleAndExecute(address(gov), data);

        assertEq(core.totalAssets(), totalBefore, "total assets preserved");
        assertEq(OllaCoreV2Mock(address(core)).version(), 2, "v2 applied");
    }

    /*//////////////////////////////////////////////////////////////
                       UPGRADE SATELLITE
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UpgradeSatellite_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.upgradeSatellite(address(vault), makeAddr("impl"));
    }

    function test_RevertWhen_UpgradeSatellite_ZeroProxy() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.upgradeSatellite, (address(0), makeAddr("impl")));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert();
        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));
    }

    function test_RevertWhen_UpgradeSatellite_ZeroImplementation() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.upgradeSatellite, (address(vault), address(0)));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(uint256(1)), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert();
        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(uint256(1)));
    }

    /*//////////////////////////////////////////////////////////////
                      SELF-UPGRADE (GOVERNANCE)
    //////////////////////////////////////////////////////////////*/

    function test_SelfUpgrade_ViaTimelock() external {
        OllaGovernanceV2Mock newImpl = new OllaGovernanceV2Mock();

        // Schedule upgradeToAndCall on the governance contract itself
        bytes memory upgradeData = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImpl), ""));
        _scheduleAndExecute(address(gov), upgradeData);

        uint256 ver = OllaGovernanceV2Mock(payable(address(gov))).version();
        assertEq(ver, 2, "governance self-upgraded");
    }

    function test_RevertWhen_SelfUpgrade_ByAttacker() external {
        OllaGovernanceV2Mock newImpl = new OllaGovernanceV2Mock();

        vm.expectRevert();
        vm.prank(alice);
        gov.upgradeToAndCall(address(newImpl), "");
    }
}
