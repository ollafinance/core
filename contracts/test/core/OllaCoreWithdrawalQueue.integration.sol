// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { IOllaCore } from "src/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockStakingManager } from "src/mocks/MockStakingManager.sol";

contract OllaCoreWithdrawalQueueHarness is OllaCore {
    /*//////////////////////////////////////////////////////////////
                           CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function exposedIncreaseRewardsVaultBalance(uint256 amount) external {
        _increaseRewardsVaultBalance(amount);
    }
}

contract OllaCoreWithdrawalQueueTest is Test {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed receiver,
        uint256 shares,
        uint256 assetsExpected,
        uint256 exchangeRate
    );

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreWithdrawalQueueHarness internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    WithdrawalQueue internal queue;
    address internal governance;
    address internal rewardsVault;
    address internal safetyModule;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreWithdrawalQueueHarness coreImplementation = new OllaCoreWithdrawalQueueHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreWithdrawalQueueHarness(address(coreProxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        governance = makeAddr("governance");
        rewardsVault = makeAddr("rewardsVault");
        safetyModule = makeAddr("safetyModule");

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        queue = WithdrawalQueue(address(queueProxy));

        vault.initialize(asset, stAztec, stakingManager, governance, address(queue), rewardsVault, safetyModule);
        queue.initialize(address(vault), governance);

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /*//////////////////////////////////////////////////////////////
                        REQUEST REDEEM FLOW
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_BurnsShares() external {
        uint256 shares = _deposit(alice, 10 ether);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(4 ether, alice);

        assertEq(requestId, 1, "request id starts at 1");
        assertEq(stAztec.balanceOf(alice), shares - 4 ether, "shares burned on request");
    }

    function test_RequestRedeem_LocksAssetsExpectedAtRequestRate() external {
        _deposit(alice, 12 ether);
        uint256 rate = vault.exchangeRate();
        uint256 shares = 5 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(request.assetsExpected, expectedAssets, "assetsExpected locked at request rate");
        assertEq(request.rate, rate, "rate locked at request time");

        vault.exposedIncreaseRewardsVaultBalance(3 ether);
        uint256 updatedRate = vault.exchangeRate();
        assertGt(updatedRate, rate, "exchange rate should increase after rewards");
        request = queue.getRequest(requestId);
        assertEq(request.assetsExpected, expectedAssets, "assetsExpected unchanged after rate update");
        assertEq(request.rate, rate, "rate remains locked after update");
    }

    function test_RequestRedeem_EventMatchesQueueStorage() external {
        _deposit(alice, 20 ether);
        uint256 rate = vault.exchangeRate();
        uint256 shares = 7 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawalRequested(1, bob, shares, expectedAssets, rate);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(request.user, bob, "queue stores receiver");
        assertEq(request.shares, shares, "queue stores share amount");
        assertEq(request.assetsExpected, expectedAssets, "queue stores assets expected");
        assertEq(request.rate, rate, "queue stores request rate");
    }

    function test_RequestRedeem_UpdatesQueueTotals() external {
        _deposit(alice, 25 ether);
        _deposit(bob, 15 ether);

        (, uint256 assetsExpectedAlice) = _requestRedeem(alice, 8 ether, alice);
        assertEq(queue.totalPendingAssets(), assetsExpectedAlice, "pending assets tracks first request");
        assertEq(queue.nextRequestId(), 2, "next request id increments after first request");
        assertEq(queue.nextPendingId(), 1, "next pending id stays at first request");

        (, uint256 assetsExpectedBob) = _requestRedeem(bob, 5 ether, bob);
        assertEq(
            queue.totalPendingAssets(), assetsExpectedAlice + assetsExpectedBob, "pending assets accumulates requests"
        );
        assertEq(queue.nextRequestId(), 3, "next request id increments after second request");
        assertEq(queue.nextPendingId(), 1, "next pending id remains earliest request");
    }

    function test_RequestRedeem_AssetsExpectedMatchesRate() external {
        _deposit(alice, 18 ether);
        vault.exposedIncreaseRewardsVaultBalance(6 ether);

        uint256 rate = vault.exchangeRate();
        uint256 shares = 9 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        (uint256 requestId,) = _requestRedeem(alice, shares, alice);
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);

        assertEq(request.assetsExpected, expectedAssets, "assetsExpected should match rate at request time");
        assertEq(request.rate, rate, "request rate should match current rate");
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ActiveRequestExists() external {
        _deposit(alice, 15 ether);

        vm.prank(alice);
        vault.requestRedeem(5 ether, alice);

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCore__PendingWithdrawalExists.selector, alice));
        vm.prank(alice);
        vault.requestRedeem(2 ether, alice);
    }

    function test_RequestRedeem_AllowsWhenPaused() external {
        _deposit(alice, 10 ether);

        vm.prank(governance);
        vault.pause();

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(4 ether, alice);

        assertEq(requestId, 1, "request should succeed while paused");
    }

    /*//////////////////////////////////////////////////////////////
                       WITHDRAWAL FINALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_FinalizeWithdrawals_UsesAvailableLiquidity() external {
        _deposit(alice, 10 ether);
        _deposit(bob, 12 ether);

        (, uint256 assetsExpectedAlice) = _requestRedeem(alice, 5 ether, alice);
        _requestRedeem(bob, 6 ether, bob);

        uint256 used = vault.finalizeWithdrawals(assetsExpectedAlice);

        assertEq(used, assetsExpectedAlice, "finalization should use available FIFO liquidity");
        IWithdrawalQueue.WithdrawalRequest memory first = queue.getRequest(1);
        IWithdrawalQueue.WithdrawalRequest memory second = queue.getRequest(2);
        assertTrue(first.finalized, "earliest request should finalize");
        assertFalse(second.finalized, "later request should remain pending");
    }

    function test_RevertWhen_FinalizeWithdrawalsPaused() external {
        _deposit(alice, 10 ether);
        (, uint256 assetsExpected) = _requestRedeem(alice, 5 ether, alice);

        vm.prank(governance);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.finalizeWithdrawals(assetsExpected);
    }

    function test_FinalizeWithdrawals_DecrementsBufferedAssets() external {
        _deposit(alice, 8 ether);
        _deposit(bob, 7 ether);

        (, uint256 assetsExpectedAlice) = _requestRedeem(alice, 4 ether, alice);
        (, uint256 assetsExpectedBob) = _requestRedeem(bob, 6 ether, bob);

        IOllaCore.AccountingState memory beforeBuckets = vault.accountingState();

        uint256 available = assetsExpectedAlice + assetsExpectedBob;
        uint256 used = vault.finalizeWithdrawals(available);

        IOllaCore.AccountingState memory afterBuckets = vault.accountingState();
        assertEq(used, available, "used should equal finalized assets");
        assertEq(
            afterBuckets.bufferedAssets, beforeBuckets.bufferedAssets - used, "buffered assets should decrement by used"
        );
    }

    function test_FinalizeWithdrawals_PreviewMatchesFinalized() external {
        _deposit(alice, 11 ether);
        _deposit(bob, 9 ether);

        (, uint256 assetsExpectedAlice) = _requestRedeem(alice, 5 ether, alice);
        (, uint256 assetsExpectedBob) = _requestRedeem(bob, 6 ether, bob);

        uint256 available = assetsExpectedAlice + assetsExpectedBob;
        uint256 previewed = queue.previewFinalizeWithdrawals(available);
        uint256 used = vault.finalizeWithdrawals(available);

        assertEq(used, previewed, "finalized amount should match preview");
    }

    function test_FinalizeWithdrawals_FinalizedRequestsClaimable() external {
        _deposit(alice, 9 ether);

        (uint256 requestId,) = _requestRedeem(alice, 5 ether, alice);

        vault.finalizeWithdrawals(5 ether);

        uint256 claimedAssets = queue.claimWithdrawal(requestId);
        assertEq(claimedAssets, 5 ether, "claim should return finalized assets");
    }

    function test_FinalizeWithdrawals_PartialLiquidityFifo() external {
        _deposit(alice, 10 ether);
        _deposit(bob, 10 ether);
        address carol = makeAddr("carol");
        _deposit(carol, 10 ether);

        (, uint256 assetsExpectedAlice) = _requestRedeem(alice, 4 ether, alice);
        _requestRedeem(bob, 6 ether, bob);
        _requestRedeem(carol, 7 ether, carol);

        uint256 available = assetsExpectedAlice + 1;
        uint256 used = vault.finalizeWithdrawals(available);

        assertEq(used, assetsExpectedAlice, "only earliest request should finalize");
        IWithdrawalQueue.WithdrawalRequest memory first = queue.getRequest(1);
        IWithdrawalQueue.WithdrawalRequest memory second = queue.getRequest(2);
        IWithdrawalQueue.WithdrawalRequest memory third = queue.getRequest(3);
        assertTrue(first.finalized, "first request should finalize");
        assertFalse(second.finalized, "second request should remain pending");
        assertFalse(third.finalized, "third request should remain pending");
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_FinalizeWithdrawals_FifoAvailable(uint96[4] memory assetsRaw, uint96 availableRaw) external {
        uint256[4] memory assetsExpected;
        uint256 totalAssets = 0;

        for (uint256 i = 0; i < assetsRaw.length; i++) {
            uint256 assets = uint256(bound(assetsRaw[i], 1, 20 ether));
            totalAssets += assets;
            address user = address(uint160(100 + i));
            _deposit(user, assets);
            (, uint256 assetsExpectedValue) = _requestRedeem(user, assets, user);
            assetsExpected[i] = assetsExpectedValue;
        }

        uint256 available = uint256(bound(availableRaw, 0, totalAssets));
        uint256 expectedUsed = 0;
        uint256 remaining = available;
        uint256 finalizedCount = 0;

        for (uint256 i = 0; i < assetsExpected.length; i++) {
            if (remaining < assetsExpected[i]) {
                break;
            }
            remaining -= assetsExpected[i];
            expectedUsed += assetsExpected[i];
            finalizedCount++;
        }

        IOllaCore.AccountingState memory beforeBuckets = vault.accountingState();
        uint256 used = vault.finalizeWithdrawals(available);
        IOllaCore.AccountingState memory afterBuckets = vault.accountingState();

        assertEq(used, expectedUsed, "used assets should match FIFO fill");
        assertEq(
            afterBuckets.bufferedAssets,
            beforeBuckets.bufferedAssets - expectedUsed,
            "buffered assets should drop by used"
        );

        for (uint256 i = 0; i < assetsExpected.length; i++) {
            IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(i + 1);
            if (i < finalizedCount) {
                assertTrue(request.finalized, "requests within liquidity should finalize");
            } else {
                assertFalse(request.finalized, "requests beyond liquidity should remain pending");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }

    function _requestRedeem(address owner, uint256 shares, address receiver)
        internal
        returns (uint256 requestId, uint256 assetsExpected)
    {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, receiver);
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assetsExpected = request.assetsExpected;
        return (requestId, assetsExpected);
    }
}
