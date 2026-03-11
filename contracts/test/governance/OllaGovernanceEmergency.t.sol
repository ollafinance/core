// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { OllaGovernanceSetup } from "./OllaGovernanceSetup.t.sol";

/// @title OllaGovernanceEmergencyTest
/// @notice Unit tests for emergencyPauseAll() and emergencyUnpauseAll().
contract OllaGovernanceEmergencyTest is OllaGovernanceSetup {
    /*//////////////////////////////////////////////////////////////
                        emergencyPauseAll
    //////////////////////////////////////////////////////////////*/

    /// @notice emergencyPauseAll pauses both core and vault.
    function test_EmergencyPauseAll_PausesBothCoreAndVault() external {
        assertFalse(core.paused(), "core should start unpaused");
        assertFalse(vault.paused(), "vault should start unpaused");

        vm.prank(admin);
        gov.emergencyPauseAll();

        assertTrue(core.paused(), "core should be paused");
        assertTrue(vault.paused(), "vault should be paused");
    }

    /// @notice emergencyPauseAll reverts when called by non-admin.
    function test_EmergencyPauseAll_OnlyGovernanceAdmin() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlyGovernanceAdmin.selector);
        vm.prank(alice);
        gov.emergencyPauseAll();
    }

    /// @notice emergencyPauseAll emits EmergencyPauseAll event.
    function test_EmergencyPauseAll_EmitsEvent() external {
        vm.expectEmit(true, true, true, true, address(gov));
        emit IOllaGovernance.EmergencyPauseAll();

        vm.prank(admin);
        gov.emergencyPauseAll();
    }

    /*//////////////////////////////////////////////////////////////
                       emergencyUnpauseAll
    //////////////////////////////////////////////////////////////*/

    /// @notice emergencyUnpauseAll unpauses both core and vault after a pause.
    function test_EmergencyUnpauseAll_UnpausesBothCoreAndVault() external {
        // Pause first
        vm.prank(admin);
        gov.emergencyPauseAll();

        assertTrue(core.paused(), "core should be paused");
        assertTrue(vault.paused(), "vault should be paused");

        // Unpause
        vm.prank(admin);
        gov.emergencyUnpauseAll();

        assertFalse(core.paused(), "core should be unpaused");
        assertFalse(vault.paused(), "vault should be unpaused");
    }

    /// @notice emergencyUnpauseAll reverts when called by non-admin.
    function test_EmergencyUnpauseAll_OnlyGovernanceAdmin() external {
        // Pause first so unpause is valid
        vm.prank(admin);
        gov.emergencyPauseAll();

        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlyGovernanceAdmin.selector);
        vm.prank(alice);
        gov.emergencyUnpauseAll();
    }

    /// @notice emergencyUnpauseAll emits EmergencyUnpauseAll event.
    function test_EmergencyUnpauseAll_EmitsEvent() external {
        // Pause first
        vm.prank(admin);
        gov.emergencyPauseAll();

        vm.expectEmit(true, true, true, true, address(gov));
        emit IOllaGovernance.EmergencyUnpauseAll();

        vm.prank(admin);
        gov.emergencyUnpauseAll();
    }
}
