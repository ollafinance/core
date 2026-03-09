// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

contract SafetyModuleEdgeCasesTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Paused();
    event Unpaused();
    event CircuitBreakerTriggered(ISafetyModule.BreakerReason reason);

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    SafetyModule internal safetyModule;
    address internal admin;
    address internal guardian;
    address internal core;
    address internal vault;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        core = makeAddr("core");
        vault = makeAddr("vault");

        safetyModule = new SafetyModule(admin, guardian, core, vault, 1_000 ether, 500, 6_000, 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                    CONSTRUCTOR ZERO-ADDRESS GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ConstructorZeroAdmin() external {
        vm.expectRevert(abi.encodeWithSelector(ISafetyModule.SafetyModule__ZeroAddress.selector, "admin"));
        new SafetyModule(address(0), guardian, core, vault, 1_000 ether, 500, 6_000, 1 days);
    }

    function test_RevertWhen_ConstructorZeroGuardian() external {
        vm.expectRevert(abi.encodeWithSelector(ISafetyModule.SafetyModule__ZeroAddress.selector, "guardian"));
        new SafetyModule(admin, address(0), core, vault, 1_000 ether, 500, 6_000, 1 days);
    }

    function test_RevertWhen_ConstructorZeroCore() external {
        vm.expectRevert(abi.encodeWithSelector(ISafetyModule.SafetyModule__ZeroAddress.selector, "core"));
        new SafetyModule(admin, guardian, address(0), vault, 1_000 ether, 500, 6_000, 1 days);
    }

    function test_RevertWhen_ConstructorZeroVault() external {
        vm.expectRevert(abi.encodeWithSelector(ISafetyModule.SafetyModule__ZeroAddress.selector, "vault"));
        new SafetyModule(admin, guardian, core, address(0), 1_000 ether, 500, 6_000, 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                      CHECK RATE DROP WITH OLD RATE ZERO
    //////////////////////////////////////////////////////////////*/

    function test_CheckRateDrop_OldRateZeroNextRateZero_ReturnsEarly() external {
        // When oldRate == 0 and nextRate == 0: nextRate >= oldRate is true, so returns early.
        // No breaker should be triggered.
        vm.prank(core);
        safetyModule.checkRateDrop(0, 0);
        assertFalse(safetyModule.isPaused(), "should not be paused after checkRateDrop(0, 0)");
    }

    /*//////////////////////////////////////////////////////////////
                      IDEMPOTENT PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_Pause_WhenAlreadyPaused_NoOp() external {
        // First pause
        vm.prank(guardian);
        safetyModule.pause();
        assertTrue(safetyModule.isPaused(), "should be paused after first pause");

        // Second pause (already paused) — exercises the early-return branch
        vm.prank(guardian);
        safetyModule.pause();
        assertTrue(safetyModule.isPaused(), "should still be paused after idempotent call");
    }

    function test_Unpause_WhenAlreadyUnpaused_NoOp() external {
        // Module starts unpaused
        assertFalse(safetyModule.isPaused(), "should start unpaused");

        // Unpause when already unpaused — exercises the early-return branch
        vm.prank(guardian);
        safetyModule.unpause();
        assertFalse(safetyModule.isPaused(), "should still be unpaused after idempotent call");
    }
}
