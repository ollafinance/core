// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { TimelockControllerUpgradeable } from "@oz-upgradeable/governance/TimelockControllerUpgradeable.sol";

import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { OllaGovernanceSetup } from "./OllaGovernanceSetup.t.sol";

/// @title OllaGovernanceTimelockTest
/// @notice Tests for the inherited TimelockController scheduling / execution flow.
contract OllaGovernanceTimelockTest is OllaGovernanceSetup {
    /*//////////////////////////////////////////////////////////////
                        SCHEDULE + EXECUTE
    //////////////////////////////////////////////////////////////*/

    function test_ScheduleAndExecute_HappyPath() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));
        bytes32 id = gov.hashOperation(address(gov), 0, data, bytes32(0), bytes32(0));

        // Schedule
        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        assertTrue(gov.isOperationPending(id), "operation pending");
        assertFalse(gov.isOperationReady(id), "not ready yet");

        // Wait
        vm.warp(block.timestamp + MIN_DELAY);
        assertTrue(gov.isOperationReady(id), "ready after delay");

        // Execute
        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));

        assertTrue(gov.isOperationDone(id), "operation done");
        assertEq(gov.treasury(), alice, "treasury updated");
    }

    function test_RevertWhen_ExecuteBeforeDelay() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        // Try to execute before delay
        vm.expectRevert();
        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));
    }

    function test_RevertWhen_UnauthorizedSchedule() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));

        vm.expectRevert();
        vm.prank(alice);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
    }

    function test_RevertWhen_UnauthorizedExecute() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert();
        vm.prank(alice);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                           CANCEL OPERATION
    //////////////////////////////////////////////////////////////*/

    function test_CancelOperation() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));
        bytes32 id = gov.hashOperation(address(gov), 0, data, bytes32(0), bytes32(0));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        assertTrue(gov.isOperationPending(id), "pending");

        vm.prank(admin);
        gov.cancel(id);
        assertFalse(gov.isOperationPending(id), "cancelled");
    }

    function test_RevertWhen_UnauthorizedCancel() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));
        bytes32 id = gov.hashOperation(address(gov), 0, data, bytes32(0), bytes32(0));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        vm.expectRevert();
        vm.prank(alice);
        gov.cancel(id);
    }

    /*//////////////////////////////////////////////////////////////
                            MIN DELAY
    //////////////////////////////////////////////////////////////*/

    function test_MinDelay() external view {
        assertEq(gov.getMinDelay(), MIN_DELAY, "min delay matches");
    }

    function test_RevertWhen_ScheduleBelowMinDelay() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));

        vm.expectRevert();
        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY - 1);
    }

    /*//////////////////////////////////////////////////////////////
                       DUPLICATE SCHEDULE
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_DuplicateSchedule() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        // Same operation, same salt -> duplicate
        vm.expectRevert();
        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
    }

    function test_ScheduleSameFunctionDifferentSalt() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        // Different salt -> allowed
        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(uint256(1)), MIN_DELAY);
    }
}
