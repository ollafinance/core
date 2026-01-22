// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/interfaces/IWithdrawalQueue.sol";

contract WithdrawalQueueTest is Test {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawalRequested(
        uint256 indexed id, address indexed recipient, uint256 shares, uint256 assetsExpected, uint256 rate
    );
    event WithdrawalFinalized(uint256 indexed id, uint256 assets);
    event WithdrawalClaimed(uint256 indexed id, address indexed recipient, uint256 assetsExpected);

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    WithdrawalQueue internal queue;
    address internal core;
    address internal admin;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        core = makeAddr("core");
        admin = makeAddr("admin");

        WithdrawalQueue implementation = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        queue = WithdrawalQueue(address(proxy));
        queue.initialize(core, admin);
    }

    /*//////////////////////////////////////////////////////////////
                         REQUEST CREATION
    //////////////////////////////////////////////////////////////*/

    function test_RequestWithdrawal_EnqueuesMonotonicIds() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.expectEmit(true, true, false, true, address(queue));
        emit WithdrawalRequested(1, alice, 100, 120, 1e18);
        uint256 firstId = _request(alice, 100, 120, 1e18);

        vm.expectEmit(true, true, false, true, address(queue));
        emit WithdrawalRequested(2, bob, 55, 70, 1.1e18);
        uint256 secondId = _request(bob, 55, 70, 1.1e18);

        assertEq(firstId, 1, "request ids should start at 1");
        assertEq(secondId, 2, "request ids should increment sequentially");
        assertEq(queue.nextRequestId(), 3, "next request id should track last + 1");
        assertEq(queue.nextPendingId(), 1, "next pending id should start at 1");
        assertEq(queue.totalPendingAssets(), 190, "pending assets should sum enqueued requests");

        IWithdrawalQueue.WithdrawalRequest memory first = queue.getRequest(firstId);
        assertEq(first.recipient, alice, "request should store the recipient address");
        assertEq(first.shares, 100, "request should store the share amount");
        assertEq(first.assetsExpected, 120, "request should store expected assets");
        assertEq(first.rate, 1e18, "request should store the locked rate");
        assertFalse(first.finalized, "new requests should not be finalized");
        assertFalse(first.claimed, "new requests should not be claimed");
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ZeroShares() public {
        address alice = makeAddr("alice");

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__ZeroAmount.selector, "shares"));
        vm.prank(core);
        queue.requestWithdrawal(alice, 0, 10, 1e18);
    }

    function test_RevertWhen_ZeroAssetsExpected() public {
        address alice = makeAddr("alice");

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__ZeroAmount.selector, "assetsExpected"));
        vm.prank(core);
        queue.requestWithdrawal(alice, 10, 0, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        FINALIZATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_FinalizeWithdrawals_FifoPartial() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        _request(alice, 10, 100, 1e18);
        _request(bob, 20, 200, 1e18);
        _request(carol, 30, 300, 1e18);

        vm.expectEmit(true, false, false, true, address(queue));
        emit WithdrawalFinalized(1, 100);

        vm.prank(core);
        uint256 used = queue.finalizeWithdrawals(250);

        assertEq(used, 100, "finalization should only use available FIFO liquidity");
        assertEq(queue.nextPendingId(), 2, "next pending id should advance past finalized requests");
        assertEq(queue.totalPendingAssets(), 500, "pending assets should drop by finalized amount");

        IWithdrawalQueue.WithdrawalRequest memory first = queue.getRequest(1);
        IWithdrawalQueue.WithdrawalRequest memory second = queue.getRequest(2);
        IWithdrawalQueue.WithdrawalRequest memory third = queue.getRequest(3);

        assertTrue(first.finalized, "first request should be finalized");
        assertFalse(second.finalized, "second request should remain pending");
        assertFalse(third.finalized, "third request should remain pending");
    }

    /*//////////////////////////////////////////////////////////////
                         PREVIEW FINALIZE
    //////////////////////////////////////////////////////////////*/

    function test_PreviewFinalizeWithdrawals_MatchesFinalizeUsed() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _request(alice, 10, 100, 1e18);
        _request(bob, 10, 200, 1e18);

        uint256 previewUsed = queue.previewFinalizeWithdrawals(250);

        vm.prank(core);
        uint256 used = queue.finalizeWithdrawals(250);

        assertEq(previewUsed, used, "preview should match finalize used");
        assertEq(queue.nextPendingId(), 2, "next pending id should advance");
    }

    function test_PreviewFinalizeWithdrawals_DoesNotMutateState() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _request(alice, 10, 100, 1e18);
        _request(bob, 10, 200, 1e18);

        uint256 nextPendingBefore = queue.nextPendingId();
        uint256 pendingBefore = queue.totalPendingAssets();

        uint256 previewUsed = queue.previewFinalizeWithdrawals(150);

        assertEq(previewUsed, 100, "preview should include only first request");
        assertEq(queue.nextPendingId(), nextPendingBefore, "preview should not advance pending id");
        assertEq(queue.totalPendingAssets(), pendingBefore, "preview should not change pending assets");
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM REQUESTS
    //////////////////////////////////////////////////////////////*/

    function test_Claim_RevertWhen_NotFinalized() public {
        address alice = makeAddr("alice");
        _request(alice, 10, 100, 1e18);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__NotFinalized.selector, 1));
        queue.claimWithdrawal(1);
    }

    function test_Claim_RevertWhen_AlreadyClaimed() public {
        address alice = makeAddr("alice");
        _request(alice, 10, 100, 1e18);

        vm.prank(core);
        queue.finalizeWithdrawals(200);

        queue.claimWithdrawal(1);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__AlreadyClaimed.selector, 1));
        queue.claimWithdrawal(1);
    }

    function test_Claim_ReturnsAssetsExpected() public {
        address alice = makeAddr("alice");
        address caller = makeAddr("caller");
        _request(alice, 10, 150, 1e18);

        vm.prank(core);
        queue.finalizeWithdrawals(200);

        vm.expectEmit(true, true, false, true, address(queue));
        emit WithdrawalClaimed(1, alice, 150);

        vm.prank(caller);
        uint256 assets = queue.claimWithdrawal(1);

        assertEq(assets, 150, "claim should return the expected assets");
        assertEq(queue.totalPendingAssets(), 0, "claim should not change pending totals");
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_FinalizeWithdrawals_FifoTotals(uint96[5] memory assetsRaw, uint96 availableRaw) public {
        uint256[5] memory assets;
        uint256 totalAssets = 0;

        for (uint256 i = 0; i < assetsRaw.length; i++) {
            assets[i] = uint256(bound(assetsRaw[i], 1, 1e18));
            totalAssets += assets[i];
            address user = address(uint160(100 + i));
            _request(user, assets[i], assets[i], 1e18);
        }

        uint256 available = uint256(bound(availableRaw, 0, totalAssets * 2));
        uint256 expectedUsed = 0;
        uint256 remaining = available;
        uint256 finalizedCount = 0;

        for (uint256 i = 0; i < assets.length; i++) {
            if (remaining < assets[i]) {
                break;
            }
            remaining -= assets[i];
            expectedUsed += assets[i];
            finalizedCount++;
        }

        vm.prank(core);
        uint256 used = queue.finalizeWithdrawals(available);

        assertEq(used, expectedUsed, "used assets should match FIFO fill");
        assertEq(queue.nextPendingId(), 1 + finalizedCount, "next pending id should equal finalized count + 1");
        assertEq(queue.totalPendingAssets(), totalAssets - expectedUsed, "pending assets should match unfinalized sum");

        for (uint256 i = 0; i < assets.length; i++) {
            IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(i + 1);
            if (i < finalizedCount) {
                assertTrue(request.finalized, "requests within liquidity should finalize");
            } else {
                assertFalse(request.finalized, "requests beyond liquidity should remain pending");
            }
        }
    }

    function testFuzz_PreviewFinalizeWithdrawals_MatchesFinalize(uint96[6] memory assetsRaw, uint96 availableRaw)
        public
    {
        uint256[6] memory assets;
        uint256 totalAssets = 0;

        for (uint256 i = 0; i < assetsRaw.length; i++) {
            assets[i] = uint256(bound(assetsRaw[i], 1, 1e18));
            totalAssets += assets[i];
            address user = address(uint160(200 + i));
            _request(user, assets[i], assets[i], 1e18);
        }

        uint256 available = uint256(bound(availableRaw, 0, totalAssets * 2));
        uint256 previewUsed = queue.previewFinalizeWithdrawals(available);

        vm.prank(core);
        uint256 used = queue.finalizeWithdrawals(available);

        assertEq(previewUsed, used, "preview should match finalize used");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _request(address user, uint256 shares, uint256 assetsExpected, uint256 rate)
        internal
        returns (uint256 requestId)
    {
        vm.prank(core);
        requestId = queue.requestWithdrawal(user, shares, assetsExpected, rate);
        return requestId;
    }
}
