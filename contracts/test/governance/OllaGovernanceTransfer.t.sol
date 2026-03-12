// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { OllaGovernanceSetup } from "./OllaGovernanceSetup.t.sol";

/// @title OllaGovernanceTransferTest
/// @notice Tests for two-step governance transfer on OllaGovernance.
contract OllaGovernanceTransferTest is OllaGovernanceSetup {
    address internal newGov;
    address internal sprMock;

    function setUp() public override {
        super.setUp();
        newGov = makeAddr("newGovernance");
        sprMock = makeAddr("sprMock");
    }

    /// @dev Mocks satellite AccessControl calls so _propagateAdminRole succeeds
    ///      with non-AccessControl mock satellites.
    function _mockSatelliteACL() internal {
        // Mock stakingProviderRegistry() to return a valid address
        vm.mockCall(
            address(stakingManager),
            abi.encodeWithSelector(IStakingManager.stakingProviderRegistry.selector),
            abi.encode(sprMock)
        );

        // Mock grantRole / revokeRole on all 5 satellite addresses
        address[5] memory sats = [
            address(withdrawalQueue),
            address(rewardsAccumulator),
            address(stakingManager),
            sprMock,
            address(safetyModule)
        ];
        for (uint256 i; i < sats.length; i++) {
            vm.mockCall(sats[i], abi.encodeWithSelector(IAccessControl.grantRole.selector), "");
            vm.mockCall(sats[i], abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PROPOSE GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function test_ProposeGovernance_ViaTimelock() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov));
        _scheduleAndExecute(address(gov), data);
        assertEq(gov.pendingGovernance(), newGov, "pending governance set");
    }

    function test_RevertWhen_ProposeGovernance_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.proposeGovernance(newGov);
    }

    function test_RevertWhen_ProposeGovernance_ZeroAddress() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.proposeGovernance, (address(0)));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert();
        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));
    }

    function test_RevertWhen_ProposeGovernance_AlreadyPending() external {
        // First proposal succeeds
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));

        // Second proposal -- schedule succeeds but execute reverts
        address anotherGov = makeAddr("anotherGov");
        bytes memory data2 = abi.encodeCall(IOllaGovernance.proposeGovernance, (anotherGov));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data2, bytes32(0), bytes32(uint256(1)), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert();
        vm.prank(admin);
        gov.execute(address(gov), 0, data2, bytes32(0), bytes32(uint256(1)));
    }

    /*//////////////////////////////////////////////////////////////
                        ACCEPT GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function test_AcceptGovernance_TransfersRoles() external {
        // Propose
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));

        // Mock satellite AccessControl so _propagateAdminRole succeeds
        _mockSatelliteACL();

        // Accept
        vm.prank(newGov);
        gov.acceptGovernance();

        // Verify state
        assertEq(gov.pendingGovernance(), address(0), "pending cleared");
        assertEq(gov.governanceAdmin(), newGov, "admin updated");

        // New governance has proposer role
        assertTrue(gov.hasRole(gov.PROPOSER_ROLE(), newGov), "newGov has PROPOSER_ROLE");
        assertTrue(gov.hasRole(gov.EXECUTOR_ROLE(), newGov), "newGov has EXECUTOR_ROLE");
        assertTrue(gov.hasRole(gov.CANCELLER_ROLE(), newGov), "newGov has CANCELLER_ROLE");

        // New governance has DEFAULT_ADMIN_ROLE
        assertTrue(gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), newGov), "newGov has DEFAULT_ADMIN_ROLE");

        // Old governance lost roles
        assertFalse(gov.hasRole(gov.PROPOSER_ROLE(), admin), "old lost PROPOSER_ROLE");
        assertFalse(gov.hasRole(gov.EXECUTOR_ROLE(), admin), "old lost EXECUTOR_ROLE");
        assertFalse(gov.hasRole(gov.CANCELLER_ROLE(), admin), "old lost CANCELLER_ROLE");
        assertFalse(gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), admin), "old lost DEFAULT_ADMIN_ROLE");
    }

    function test_RevertWhen_AcceptGovernance_NotPending() external {
        // Propose
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));

        // Random caller tries to accept
        vm.expectRevert(
            abi.encodeWithSelector(IOllaGovernance.OllaGovernance__UnauthorizedPendingGovernance.selector, alice)
        );
        vm.prank(alice);
        gov.acceptGovernance();
    }

    function test_RevertWhen_AcceptGovernance_NoPending() external {
        vm.expectRevert(
            abi.encodeWithSelector(IOllaGovernance.OllaGovernance__UnauthorizedPendingGovernance.selector, newGov)
        );
        vm.prank(newGov);
        gov.acceptGovernance();
    }

    /*//////////////////////////////////////////////////////////////
                      CANCEL GOVERNANCE PROPOSAL
    //////////////////////////////////////////////////////////////*/

    function test_CancelGovernanceProposal_ViaTimelock() external {
        // Propose
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));
        assertEq(gov.pendingGovernance(), newGov, "pending set");

        // Cancel via timelock
        bytes memory cancelData = abi.encodeCall(IOllaGovernance.cancelGovernanceProposal, ());
        _scheduleAndExecute(address(gov), cancelData, bytes32(uint256(2)));

        assertEq(gov.pendingGovernance(), address(0), "pending cleared after cancel");
    }

    function test_RevertWhen_CancelGovernanceProposal_NoPending() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.cancelGovernanceProposal, ());

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert();
        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));
    }

    function test_RevertWhen_CancelGovernanceProposal_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.cancelGovernanceProposal();
    }

    /*//////////////////////////////////////////////////////////////
                    GOVERNANCE TRANSFER FULL FLOW
    //////////////////////////////////////////////////////////////*/

    function test_FullGovernanceTransfer_NewAdminCanSchedule() external {
        // Propose + accept
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));
        _mockSatelliteACL();
        vm.prank(newGov);
        gov.acceptGovernance();

        // New admin can schedule a treasury change
        bytes memory treasuryData = abi.encodeCall(IOllaGovernance.setTreasury, (alice));
        vm.prank(newGov);
        gov.schedule(address(gov), 0, treasuryData, bytes32(0), bytes32(uint256(99)), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(newGov);
        gov.execute(address(gov), 0, treasuryData, bytes32(0), bytes32(uint256(99)));

        assertEq(gov.treasury(), alice, "new admin changed treasury");
    }

    function test_OldAdmin_CannotRegrantRolesAfterTransfer() external {
        bytes32 proposerRole = gov.PROPOSER_ROLE();
        bytes32 executorRole = gov.EXECUTOR_ROLE();
        bytes32 defaultAdminRole = gov.DEFAULT_ADMIN_ROLE();

        // Propose + accept
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));
        _mockSatelliteACL();
        vm.prank(newGov);
        gov.acceptGovernance();

        // Old admin cannot re-grant itself PROPOSER_ROLE via DEFAULT_ADMIN_ROLE
        vm.expectRevert();
        vm.prank(admin);
        gov.grantRole(proposerRole, admin);

        // Old admin cannot re-grant itself EXECUTOR_ROLE
        vm.expectRevert();
        vm.prank(admin);
        gov.grantRole(executorRole, admin);

        // Old admin cannot re-grant itself DEFAULT_ADMIN_ROLE
        vm.expectRevert();
        vm.prank(admin);
        gov.grantRole(defaultAdminRole, admin);
    }

    function test_AcceptGovernance_EmitsEventOnSatelliteFailure() external {
        // Propose
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));

        // Mock stakingProviderRegistry() to return a valid address
        vm.mockCall(
            address(stakingManager),
            abi.encodeWithSelector(IStakingManager.stakingProviderRegistry.selector),
            abi.encode(sprMock)
        );

        // Mock grantRole to succeed on vault and rewardsAccumulator, but revert on stakingManager
        vm.mockCall(address(withdrawalQueue), abi.encodeWithSelector(IAccessControl.grantRole.selector), "");
        vm.mockCall(address(rewardsAccumulator), abi.encodeWithSelector(IAccessControl.grantRole.selector), "");
        vm.mockCallRevert(
            address(stakingManager), abi.encodeWithSelector(IAccessControl.grantRole.selector), "mock revert"
        );
        vm.mockCall(sprMock, abi.encodeWithSelector(IAccessControl.grantRole.selector), "");
        vm.mockCall(address(safetyModule), abi.encodeWithSelector(IAccessControl.grantRole.selector), "");

        // Mock revokeRole to succeed on all
        vm.mockCall(address(withdrawalQueue), abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");
        vm.mockCall(address(rewardsAccumulator), abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");
        vm.mockCall(address(stakingManager), abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");
        vm.mockCall(sprMock, abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");
        vm.mockCall(address(safetyModule), abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");

        // Expect the failure event for stakingManager grant
        vm.expectEmit(true, true, false, true);
        emit IOllaGovernance.AdminRolePropagationFailed(address(stakingManager), newGov, true);

        // Accept should NOT revert despite the satellite failure
        vm.prank(newGov);
        gov.acceptGovernance();

        // Core governance transfer still completed
        assertEq(gov.governanceAdmin(), newGov, "admin updated despite satellite failure");
        assertTrue(gov.hasRole(gov.PROPOSER_ROLE(), newGov), "newGov has PROPOSER_ROLE");
    }

    function test_OldAdmin_CannotScheduleAfterTransfer() external {
        // Propose + accept
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));
        _mockSatelliteACL();
        vm.prank(newGov);
        gov.acceptGovernance();

        // Old admin can no longer schedule
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));
        vm.expectRevert();
        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(uint256(100)), MIN_DELAY);
    }

    /*//////////////////////////////////////////////////////////////
            REVOKE ROLE CATCH BLOCK IN _propagateAdminRole
    //////////////////////////////////////////////////////////////*/

    function test_AcceptGovernance_EmitsEventOnRevokeRoleFailure() external {
        // Propose
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));

        // Mock stakingProviderRegistry() to return a valid address
        vm.mockCall(
            address(stakingManager),
            abi.encodeWithSelector(IStakingManager.stakingProviderRegistry.selector),
            abi.encode(sprMock)
        );

        // Mock grantRole to succeed on ALL satellites
        address[5] memory sats = [
            address(withdrawalQueue),
            address(rewardsAccumulator),
            address(stakingManager),
            sprMock,
            address(safetyModule)
        ];
        for (uint256 i; i < sats.length; i++) {
            vm.mockCall(sats[i], abi.encodeWithSelector(IAccessControl.grantRole.selector), "");
        }

        // Mock revokeRole to succeed on all EXCEPT stakingManager
        vm.mockCall(address(withdrawalQueue), abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");
        vm.mockCall(address(rewardsAccumulator), abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");
        vm.mockCallRevert(
            address(stakingManager), abi.encodeWithSelector(IAccessControl.revokeRole.selector), "mock revert"
        );
        vm.mockCall(sprMock, abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");
        vm.mockCall(address(safetyModule), abi.encodeWithSelector(IAccessControl.revokeRole.selector), "");

        // Expect the failure event for stakingManager revoke (isGrant = false)
        vm.expectEmit(true, true, true, true);
        emit IOllaGovernance.AdminRolePropagationFailed(address(stakingManager), admin, false);

        // Accept should NOT revert despite the satellite revoke failure
        vm.prank(newGov);
        gov.acceptGovernance();

        // Core governance transfer still completed
        assertEq(gov.governanceAdmin(), newGov, "admin updated despite satellite revoke failure");
        assertTrue(gov.hasRole(gov.PROPOSER_ROLE(), newGov), "newGov has PROPOSER_ROLE");
    }
}
