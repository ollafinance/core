// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

contract SafetyModuleTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Paused();
    event Unpaused();
    event DepositCapUpdated(uint256 cap);
    event WithdrawalMinimumUpdated(uint256 minimum);
    event CircuitBreakerTriggered(ISafetyModule.BreakerReason reason);
    event RateDropLimitUpdated(uint256 minRateDropBps);
    event QueueRatioLimitUpdated(uint256 maxQueueRatioBps);
    event AccountingDelayUpdated(uint256 maxAccountingDelay);
    event AccountingTimestampUpdated(uint256 latestAccountingTimestamp);

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    SafetyModule internal safetyModule;
    address internal admin;
    address internal guardian;
    address internal core;
    address internal vault;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        core = makeAddr("core");
        vault = makeAddr("vault");
        alice = makeAddr("alice");

        safetyModule = new SafetyModule(admin, guardian, core, vault, 1_000 ether, 500, 6_000, 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                           ROLE RESTRICTIONS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_PauseUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, safetyModule.GUARDIAN_ROLE()
            )
        );
        vm.prank(alice);
        safetyModule.pause();
    }

    function test_RevertWhen_UnpauseUnauthorized() public {
        vm.prank(guardian);
        safetyModule.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, safetyModule.GUARDIAN_ROLE()
            )
        );
        vm.prank(alice);
        safetyModule.unpause();
    }

    function test_RevertWhen_SetDepositCapUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, safetyModule.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        safetyModule.setDepositCap(2_000 ether);
    }

    function test_RevertWhen_SetWithdrawalMinimumUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, safetyModule.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        safetyModule.setWithdrawalMinimum(1 ether);
    }

    function test_RevertWhen_SetMinRateDropBpsUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, safetyModule.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        safetyModule.setMinRateDropBps(800);
    }

    function test_RevertWhen_SetMaxQueueRatioBpsUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, safetyModule.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        safetyModule.setMaxQueueRatioBps(8_000);
    }

    function test_RevertWhen_SetMaxAccountingDelayUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, safetyModule.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        safetyModule.setMaxAccountingDelay(2 days);
    }

    function test_RevertWhen_SetLastAccountingTimestampUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(ISafetyModule.SafetyModule__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        safetyModule.setLatestAccountingTimestamp(123);
    }

    function test_Pause_Unpause_Authorized() public {
        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit Paused();
        vm.prank(guardian);
        safetyModule.pause();

        assertTrue(safetyModule.isPaused(), "paused should be true after pause");

        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit Unpaused();
        vm.prank(guardian);
        safetyModule.unpause();

        assertFalse(safetyModule.isPaused(), "paused should be false after unpause");
    }

    function test_SetDepositCap_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit DepositCapUpdated(2_000 ether);

        vm.prank(admin);
        safetyModule.setDepositCap(2_000 ether);

        assertEq(safetyModule.depositCap(), 2_000 ether, "deposit cap should update");
    }

    function test_SetWithdrawalMinimum_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit WithdrawalMinimumUpdated(5 ether);

        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(5 ether);

        assertEq(safetyModule.withdrawalMinimum(), 5 ether, "withdrawal minimum should update");
    }

    function test_SetMinRateDropBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit RateDropLimitUpdated(900);

        vm.prank(admin);
        safetyModule.setMinRateDropBps(900);

        assertEq(safetyModule.minRateDropBps(), 900, "min rate drop should update");
    }

    function test_SetMaxQueueRatioBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit QueueRatioLimitUpdated(7_500);

        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(7_500);

        assertEq(safetyModule.maxQueueRatioBps(), 7_500, "max queue ratio should update");
    }

    function test_SetMaxAccountingDelay_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit AccountingDelayUpdated(3 days);

        vm.prank(admin);
        safetyModule.setMaxAccountingDelay(3 days);

        assertEq(safetyModule.maxAccountingDelay(), 3 days, "max accounting delay should update");
    }

    function test_SetLastAccountingTimestamp_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit AccountingTimestampUpdated(block.timestamp);

        vm.prank(core);
        safetyModule.setLatestAccountingTimestamp(block.timestamp);

        assertEq(safetyModule.lastAccountingTimestamp(), block.timestamp, "last accounting timestamp should update");
    }

    function test_RevertWhen_SetLastAccountingTimestampFutureValue() public {
        vm.expectRevert(abi.encodeWithSelector(ISafetyModule.SafetyModule__InvalidParameter.selector));
        vm.prank(core);
        safetyModule.setLatestAccountingTimestamp(block.timestamp + 1);
    }

    /*//////////////////////////////////////////////////////////////
                           CIRCUIT BREAKERS
    //////////////////////////////////////////////////////////////*/

    function test_CheckRateDrop_TriggersBreaker() public {
        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.RateDrop);

        vm.prank(core);
        safetyModule.checkRateDrop(1e18, 9e17);

        assertTrue(safetyModule.isPaused(), "rate-drop breach should pause");
    }

    function test_CheckQueueRatio_TriggersBreaker() public {
        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.QueueRatio);

        vm.prank(core);
        safetyModule.checkQueueRatio(600, 1_000);

        assertTrue(safetyModule.isPaused(), "queue ratio breach should pause");
    }

    function test_CheckAccountingLiveness_TriggersBreaker() public {
        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.AccountingStale);

        vm.prank(core);
        safetyModule.checkAccountingLiveness();

        assertTrue(safetyModule.isPaused(), "stale accounting should pause");
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT CAP CHECK
    //////////////////////////////////////////////////////////////*/

    function test_CheckDepositAllowed_ReturnsFalseWhenCapExceeded() public {
        vm.prank(core);
        bool allowed = safetyModule.checkDepositAllowed(600 ether, 500 ether);

        assertFalse(allowed, "deposit should be blocked when cap exceeded");
    }

    function test_CheckDepositAllowed_OverflowReturnsFalse() public {
        vm.prank(core);
        bool allowed = safetyModule.checkDepositAllowed(type(uint256).max, type(uint256).max);

        assertFalse(allowed, "overflow inputs should return false, not revert");
    }

    function test_CheckDepositAllowed_AtCapReturnsTrue() public {
        vm.prank(core);
        bool allowed = safetyModule.checkDepositAllowed(500 ether, 500 ether);

        assertTrue(allowed, "deposit exactly at cap should be allowed");
    }

    function test_CheckDepositAllowed_AboveCapReturnsFalse() public {
        vm.prank(core);
        bool allowed = safetyModule.checkDepositAllowed(500 ether, 501 ether);

        assertFalse(allowed, "deposit above cap should be blocked");
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL MINIMUM CHECK
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CheckWithdrawalMinimumBelowThreshold() public {
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ISafetyModule.SafetyModule__BelowWithdrawalMinimum.selector, 5 ether, 10 ether)
        );
        vm.prank(core);
        safetyModule.checkWithdrawalMinimum(5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    CIRCUIT BREAKER BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Exactly 500 bps rate drop triggers the breaker (>= threshold).
    function test_CheckRateDrop_ExactBoundary_Pauses() public {
        // dropBps = (10000 - 9500) * 10000 / 10000 = 500  (== minRateDropBps)
        uint256 oldRate = 10_000;
        uint256 nextRate = 9_500;

        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.RateDrop);

        vm.prank(core);
        safetyModule.checkRateDrop(oldRate, nextRate);

        assertTrue(safetyModule.isPaused(), "exact 500 bps drop should pause");
    }

    /// @notice 499 bps rate drop does NOT trigger the breaker (< threshold).
    function test_CheckRateDrop_ExactBoundary_NoPause() public {
        // dropBps = (10000 - 9501) * 10000 / 10000 = 499  (< minRateDropBps)
        uint256 oldRate = 10_000;
        uint256 nextRate = 9_501;

        vm.prank(core);
        safetyModule.checkRateDrop(oldRate, nextRate);

        assertFalse(safetyModule.isPaused(), "499 bps drop should not pause");
    }

    /// @notice Exactly 60% queue ratio triggers the breaker (>= threshold).
    function test_CheckQueueRatio_ExactBoundary_Pauses() public {
        // ratioBps = 6000 * 10000 / 10000 = 6000  (== maxQueueRatioBps)
        uint256 queued = 6_000;
        uint256 total = 10_000;

        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.QueueRatio);

        vm.prank(core);
        safetyModule.checkQueueRatio(queued, total);

        assertTrue(safetyModule.isPaused(), "exact 60% queue ratio should pause");
    }

    /// @notice 59.99% queue ratio does NOT trigger the breaker (< threshold).
    function test_CheckQueueRatio_ExactBoundary_NoPause() public {
        // ratioBps = 5999 * 10000 / 10000 = 5999  (< maxQueueRatioBps)
        uint256 queued = 5_999;
        uint256 total = 10_000;

        vm.prank(core);
        safetyModule.checkQueueRatio(queued, total);

        assertFalse(safetyModule.isPaused(), "59.99% queue ratio should not pause");
    }

    /// @notice 1 day + 1 second elapsed triggers the breaker (> threshold).
    function test_CheckAccountingLiveness_ExactBoundary_Pauses() public {
        // elapsed = 1 days + 1  (> maxAccountingDelay)
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.AccountingStale);

        vm.prank(core);
        safetyModule.checkAccountingLiveness();

        assertTrue(safetyModule.isPaused(), "1 day + 1s elapsed should pause");
    }

    /// @notice Exactly 1 day elapsed does NOT trigger the breaker (<= threshold with strict >).
    function test_CheckAccountingLiveness_ExactBoundary_NoPause() public {
        // elapsed = 1 days  (== maxAccountingDelay, not > so no trigger)
        vm.warp(block.timestamp + 1 days);

        vm.prank(core);
        safetyModule.checkAccountingLiveness();

        assertFalse(safetyModule.isPaused(), "exactly 1 day elapsed should not pause");
    }
}
