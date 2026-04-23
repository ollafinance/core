// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { OllaGovernanceSetup } from "./OllaGovernanceSetup.t.sol";

/// @title OllaGovernanceTransferTest
/// @notice Tests for two-step governance transfer on OllaGovernance.
contract OllaGovernanceTransferTest is OllaGovernanceSetup {
    uint256 internal constant REAL_SAFETY_MODULE_CAP = 1_000_000 ether;

    address internal newGov;
    address internal safetyGuardian;

    function setUp() public override {
        super.setUp();
        newGov = makeAddr("newGovernance");
        safetyGuardian = makeAddr("safetyGuardian");
    }

    function _deployRealSafetyModuleWithGovernanceContractAsAdmin() internal returns (SafetyModule realSafetyModule) {
        realSafetyModule = new SafetyModule(
            address(gov), safetyGuardian, address(core), address(vault), REAL_SAFETY_MODULE_CAP, 500, 6_000, 1 days
        );

        vm.prank(address(gov));
        core.setSafetyModule(address(realSafetyModule));
    }

    function _seedVaultBuffer(uint256 amount) internal {
        asset.mint(address(vault), amount);

        vm.prank(address(core));
        vault.receiveUnstaked(amount);
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

    function test_AcceptGovernance_KeepsSafetyModuleAdminOnGovernanceContract() external {
        SafetyModule realSafetyModule = _deployRealSafetyModuleWithGovernanceContractAsAdmin();

        assertTrue(
            realSafetyModule.hasRole(realSafetyModule.DEFAULT_ADMIN_ROLE(), address(gov)),
            "governance contract starts as safety module admin"
        );
        assertFalse(
            realSafetyModule.hasRole(realSafetyModule.DEFAULT_ADMIN_ROLE(), newGov),
            "new governance wallet starts without safety module admin"
        );

        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));

        vm.prank(newGov);
        gov.acceptGovernance();

        assertFalse(
            realSafetyModule.hasRole(realSafetyModule.DEFAULT_ADMIN_ROLE(), newGov),
            "incoming governance wallet should not receive direct safety module admin"
        );
        assertTrue(
            realSafetyModule.hasRole(realSafetyModule.DEFAULT_ADMIN_ROLE(), address(gov)),
            "governance contract should retain safety module admin"
        );
    }

    function test_AcceptGovernance_NewGovernanceWalletCannotDirectlyChangeSafetyModuleParams() external {
        SafetyModule realSafetyModule = _deployRealSafetyModuleWithGovernanceContractAsAdmin();
        uint256 originalCap = realSafetyModule.depositCap();

        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));

        vm.prank(newGov);
        gov.acceptGovernance();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, newGov, realSafetyModule.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(newGov);
        realSafetyModule.setDepositCap(1);

        assertEq(
            realSafetyModule.depositCap(), originalCap, "direct wallet call should not change safety module params"
        );
    }

    function test_AcceptGovernance_NewGovernanceWalletCannotSelfGrantCoreRoleOnVault() external {
        bytes32 coreRole = vault.CORE_ROLE();

        _seedVaultBuffer(10 ether);
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));

        vm.prank(newGov);
        gov.acceptGovernance();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, newGov, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(newGov);
        vault.grantRole(coreRole, newGov);
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

    function test_OldAdmin_CannotScheduleAfterTransfer() external {
        // Propose + accept
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.proposeGovernance, (newGov)));
        vm.prank(newGov);
        gov.acceptGovernance();

        // Old admin can no longer schedule
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (alice));
        vm.expectRevert();
        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(uint256(100)), MIN_DELAY);
    }
}
