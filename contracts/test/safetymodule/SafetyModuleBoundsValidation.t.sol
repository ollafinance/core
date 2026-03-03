// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

contract SafetyModuleBoundsValidationTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 STATE
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
                      CONSTRUCTOR BOUNDS VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Constructor_DepositCapZero() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        new SafetyModule(admin, guardian, core, vault, 0, 500, 6_000, 1 days);
    }

    function test_RevertWhen_Constructor_MinRateDropBpsBelowMin() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        new SafetyModule(admin, guardian, core, vault, 1_000 ether, 0, 6_000, 1 days);
    }

    function test_RevertWhen_Constructor_MinRateDropBpsAboveMax() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        new SafetyModule(admin, guardian, core, vault, 1_000 ether, 5_001, 6_000, 1 days);
    }

    function test_RevertWhen_Constructor_MaxQueueRatioBpsBelowMin() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        new SafetyModule(admin, guardian, core, vault, 1_000 ether, 500, 99, 1 days);
    }

    function test_RevertWhen_Constructor_MaxQueueRatioBpsAboveMax() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        new SafetyModule(admin, guardian, core, vault, 1_000 ether, 500, 9_001, 1 days);
    }

    function test_RevertWhen_Constructor_MaxAccountingDelayBelowMin() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        new SafetyModule(admin, guardian, core, vault, 1_000 ether, 500, 6_000, 1 hours - 1);
    }

    function test_RevertWhen_Constructor_MaxAccountingDelayAboveMax() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        new SafetyModule(admin, guardian, core, vault, 1_000 ether, 500, 6_000, 7 days + 1);
    }

    /*//////////////////////////////////////////////////////////////
                     SET DEPOSIT CAP BOUNDS VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetDepositCap_Zero() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setDepositCap(0);
    }

    function test_SetDepositCap_MinBoundary() public {
        vm.prank(admin);
        safetyModule.setDepositCap(1);
        assertEq(safetyModule.depositCap(), 1);
    }

    function testFuzz_SetDepositCap_ValidRange(uint256 cap) public {
        cap = bound(cap, 1, type(uint256).max);
        vm.prank(admin);
        safetyModule.setDepositCap(cap);
        assertEq(safetyModule.depositCap(), cap);
    }

    /*//////////////////////////////////////////////////////////////
                 SET WITHDRAWAL MINIMUM BOUNDS VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetWithdrawalMinimum_AboveMax() public {
        uint256 maxWithdrawalMinimum = safetyModule.MAX_WITHDRAWAL_MINIMUM();
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(maxWithdrawalMinimum + 1);
    }

    function test_SetWithdrawalMinimum_Zero() public {
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(0);
        assertEq(safetyModule.withdrawalMinimum(), 0);
    }

    function test_SetWithdrawalMinimum_MaxBoundary() public {
        uint256 maxWithdrawalMinimum = safetyModule.MAX_WITHDRAWAL_MINIMUM();
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(maxWithdrawalMinimum);
        assertEq(safetyModule.withdrawalMinimum(), maxWithdrawalMinimum);
    }

    function testFuzz_SetWithdrawalMinimum_ValidRange(uint256 minimumShares) public {
        uint256 maxWithdrawalMinimum = safetyModule.MAX_WITHDRAWAL_MINIMUM();
        minimumShares = bound(minimumShares, 0, maxWithdrawalMinimum);
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(minimumShares);
        assertEq(safetyModule.withdrawalMinimum(), minimumShares);
    }

    function testFuzz_RevertWhen_SetWithdrawalMinimum_AboveMax(uint256 minimumShares) public {
        uint256 maxWithdrawalMinimum = safetyModule.MAX_WITHDRAWAL_MINIMUM();
        minimumShares = bound(minimumShares, maxWithdrawalMinimum + 1, type(uint256).max);
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(minimumShares);
    }

    /*//////////////////////////////////////////////////////////////
                 SET MIN RATE DROP BPS BOUNDS VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetMinRateDropBps_BelowMin() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMinRateDropBps(0);
    }

    function test_RevertWhen_SetMinRateDropBps_AboveMax() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMinRateDropBps(5_001);
    }

    function test_SetMinRateDropBps_MinBoundary() public {
        vm.prank(admin);
        safetyModule.setMinRateDropBps(1);
        assertEq(safetyModule.minRateDropBps(), 1);
    }

    function test_SetMinRateDropBps_MaxBoundary() public {
        vm.prank(admin);
        safetyModule.setMinRateDropBps(5_000);
        assertEq(safetyModule.minRateDropBps(), 5_000);
    }

    function testFuzz_SetMinRateDropBps_ValidRange(uint256 bps) public {
        bps = bound(bps, 1, 5_000);
        vm.prank(admin);
        safetyModule.setMinRateDropBps(bps);
        assertEq(safetyModule.minRateDropBps(), bps);
    }

    function testFuzz_RevertWhen_SetMinRateDropBps_AboveMax(uint256 bps) public {
        bps = bound(bps, 5_001, type(uint256).max);
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMinRateDropBps(bps);
    }

    /*//////////////////////////////////////////////////////////////
                SET MAX QUEUE RATIO BPS BOUNDS VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetMaxQueueRatioBps_BelowMin() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(99);
    }

    function test_RevertWhen_SetMaxQueueRatioBps_AboveMax() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(9_001);
    }

    function test_SetMaxQueueRatioBps_MinBoundary() public {
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(100);
        assertEq(safetyModule.maxQueueRatioBps(), 100);
    }

    function test_SetMaxQueueRatioBps_MaxBoundary() public {
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(9_000);
        assertEq(safetyModule.maxQueueRatioBps(), 9_000);
    }

    function testFuzz_SetMaxQueueRatioBps_ValidRange(uint256 bps) public {
        bps = bound(bps, 100, 9_000);
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(bps);
        assertEq(safetyModule.maxQueueRatioBps(), bps);
    }

    function testFuzz_RevertWhen_SetMaxQueueRatioBps_BelowMin(uint256 bps) public {
        bps = bound(bps, 0, 99);
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(bps);
    }

    function testFuzz_RevertWhen_SetMaxQueueRatioBps_AboveMax(uint256 bps) public {
        bps = bound(bps, 9_001, type(uint256).max);
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(bps);
    }

    /*//////////////////////////////////////////////////////////////
               SET MAX ACCOUNTING DELAY BOUNDS VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetMaxAccountingDelay_BelowMin() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMaxAccountingDelay(1 hours - 1);
    }

    function test_RevertWhen_SetMaxAccountingDelay_AboveMax() public {
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMaxAccountingDelay(7 days + 1);
    }

    function test_SetMaxAccountingDelay_MinBoundary() public {
        vm.prank(admin);
        safetyModule.setMaxAccountingDelay(1 hours);
        assertEq(safetyModule.maxAccountingDelay(), 1 hours);
    }

    function test_SetMaxAccountingDelay_MaxBoundary() public {
        vm.prank(admin);
        safetyModule.setMaxAccountingDelay(7 days);
        assertEq(safetyModule.maxAccountingDelay(), 7 days);
    }

    function testFuzz_SetMaxAccountingDelay_ValidRange(uint256 delay) public {
        delay = bound(delay, 1 hours, 7 days);
        vm.prank(admin);
        safetyModule.setMaxAccountingDelay(delay);
        assertEq(safetyModule.maxAccountingDelay(), delay);
    }

    function testFuzz_RevertWhen_SetMaxAccountingDelay_BelowMin(uint256 delay) public {
        delay = bound(delay, 0, 1 hours - 1);
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMaxAccountingDelay(delay);
    }

    function testFuzz_RevertWhen_SetMaxAccountingDelay_AboveMax(uint256 delay) public {
        delay = bound(delay, 7 days + 1, type(uint256).max);
        vm.expectRevert(ISafetyModule.SafetyModule__InvalidParameter.selector);
        vm.prank(admin);
        safetyModule.setMaxAccountingDelay(delay);
    }
}
