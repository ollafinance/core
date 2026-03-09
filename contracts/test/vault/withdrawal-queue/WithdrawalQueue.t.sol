// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

contract WithdrawalQueueTest is Test {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawalRequested(
        uint256 indexed id, address indexed recipient, uint256 shares, uint256 assetsExpected, uint256 rate
    );
    event WithdrawalFinalized(uint256 indexed id, uint256 assets);
    event WithdrawalAdjusted(uint256 indexed id, uint256 originalAmount, uint256 adjustedAmount);
    event WithdrawalClaimed(uint256 indexed id, address indexed recipient, uint256 assetsExpected);

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    WithdrawalQueue internal queue;
    address internal vault;
    address internal admin;

    /// @dev Rate passed as currentRate when no slashing adjustment is intended.
    uint256 internal constant NO_SLASH_RATE = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        vault = makeAddr("vault");
        admin = makeAddr("admin");

        WithdrawalQueue implementation = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        queue = WithdrawalQueue(address(proxy));
        queue.initialize(vault, admin, 50_000);
    }

    /*//////////////////////////////////////////////////////////////
                         REQUEST CREATION
    //////////////////////////////////////////////////////////////*/

    function test_RequestWithdrawal_EnqueuesMonotonicIds() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.expectEmit(true, true, false, true, address(queue));
        emit WithdrawalRequested(1, alice, 120, 120, 1e18);
        uint256 firstId = _request(alice, 120, 120, 1e18);

        vm.expectEmit(true, true, false, true, address(queue));
        emit WithdrawalRequested(2, bob, 55, 60, 1.1e18);
        uint256 secondId = _request(bob, 55, 60, 1.1e18);

        assertEq(firstId, 1, "request ids should start at 1");
        assertEq(secondId, 2, "request ids should increment sequentially");
        assertEq(queue.nextRequestId(), 3, "next request id should track last + 1");
        assertEq(queue.nextPendingId(), 1, "next pending id should start at 1");
        assertEq(queue.totalPendingAssets(), 180, "pending assets should sum enqueued requests");

        IWithdrawalQueue.WithdrawalRequest memory first = queue.getRequest(firstId);
        assertEq(first.recipient, alice, "request should store the recipient address");
        assertEq(first.shares, 120, "request should store the share amount");
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
        vm.prank(vault);
        queue.requestWithdrawal(alice, 0, 10, 1e18);
    }

    function test_RevertWhen_ZeroAssetsExpected() public {
        address alice = makeAddr("alice");

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__ZeroAmount.selector, "assetsExpected"));
        vm.prank(vault);
        queue.requestWithdrawal(alice, 10, 0, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        FINALIZATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_FinalizeWithdrawals_FifoPartial() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        _request(alice, 100, 100, 1e18);
        _request(bob, 200, 200, 1e18);
        _request(carol, 300, 300, 1e18);

        vm.expectEmit(true, false, false, true, address(queue));
        emit WithdrawalFinalized(1, 100);

        vm.prank(vault);
        (uint256 used, uint256 finalizedCount,) = queue.finalizeWithdrawals(250, NO_SLASH_RATE);

        assertEq(used, 100, "finalization should only use available FIFO liquidity");
        assertEq(finalizedCount, 1, "finalization should report finalized request count");
        assertEq(queue.nextPendingId(), 2, "next pending id should advance past finalized requests");
        assertEq(queue.totalPendingAssets(), 500, "pending assets should drop by finalized amount");

        IWithdrawalQueue.WithdrawalRequest memory first = queue.getRequest(1);
        IWithdrawalQueue.WithdrawalRequest memory second = queue.getRequest(2);
        IWithdrawalQueue.WithdrawalRequest memory third = queue.getRequest(3);

        assertTrue(first.finalized, "first request should be finalized");
        assertFalse(second.finalized, "second request should remain pending");
        assertFalse(third.finalized, "third request should remain pending");
    }

    function test_FinalizeWithdrawals_UsedMatchesCountForUniformAssets() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        uint256 assetsExpected = 50;
        _request(alice, assetsExpected, assetsExpected, 1e18);
        _request(bob, assetsExpected, assetsExpected, 1e18);
        _request(carol, assetsExpected, assetsExpected, 1e18);

        vm.prank(vault);
        (uint256 used, uint256 finalizedCount,) = queue.finalizeWithdrawals(assetsExpected * 2, NO_SLASH_RATE);

        assertEq(used, finalizedCount * assetsExpected, "used should equal count times assetsExpected");
    }

    function test_FinalizeWithdrawals_BoundedGasMakesPartialProgress() public {
        uint256 totalRequests = 20;
        uint256 assetsExpected = 1;

        for (uint256 i = 0; i < totalRequests; i++) {
            // casting to uint160 is safe because 1000 + i stays within 160 bits
            // forge-lint: disable-next-line(unsafe-typecast)
            address user = address(uint160(1000 + i));
            _request(user, assetsExpected, assetsExpected, 1e18);
        }

        uint256 available = totalRequests * assetsExpected;
        uint256 snapshotId = vm.snapshotState();

        uint256 selectedGas;
        uint256 probedUsed;
        uint256 probedFinalizedCount;
        uint256[5] memory gasOptions = [uint256(80_000), 100_000, 120_000, 160_000, 200_000];

        for (uint256 i = 0; i < gasOptions.length; i++) {
            vm.revertToState(snapshotId);
            vm.prank(vault);
            (bool success, bytes memory data) = address(queue)
            .call{ gas: gasOptions[i] }(abi.encodeCall(queue.finalizeWithdrawals, (available, NO_SLASH_RATE)));

            if (!success) {
                continue;
            }

            (uint256 usedCandidate, uint256 finalizedCandidate,) = abi.decode(data, (uint256, uint256, uint256));
            if (finalizedCandidate > 0 && finalizedCandidate < totalRequests) {
                selectedGas = gasOptions[i];
                probedUsed = usedCandidate;
                probedFinalizedCount = finalizedCandidate;
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial finalization");

        vm.revertToState(snapshotId);
        vm.prank(vault);
        (uint256 usedObserved, uint256 finalizedCountObserved,) =
            queue.finalizeWithdrawals{ gas: selectedGas }(available, NO_SLASH_RATE);

        assertEq(usedObserved, probedUsed, "used should match probe");
        assertEq(finalizedCountObserved, probedFinalizedCount, "finalized count should match probe");
        assertEq(
            usedObserved, finalizedCountObserved * assetsExpected, "used should match finalized count times assets"
        );
        assertEq(queue.nextPendingId(), 1 + finalizedCountObserved, "next pending id advances by finalized count");
        assertEq(
            queue.totalPendingAssets(),
            (totalRequests - finalizedCountObserved) * assetsExpected,
            "pending assets track remaining"
        );

        vm.prank(vault);
        queue.finalizeWithdrawals(available, NO_SLASH_RATE);

        assertEq(queue.nextPendingId(), totalRequests + 1, "next pending id reaches end");
        assertEq(queue.totalPendingAssets(), 0, "pending assets drained");
    }

    /*//////////////////////////////////////////////////////////////
                     ZERO-PAYOUT SLASHING ADJUSTMENT
    //////////////////////////////////////////////////////////////*/

    function test_FinalizeWithdrawals_ZeroPayoutAfterSlashing_DoesNotCountAsFinalized() public {
        address alice = makeAddr("alice");
        uint256 shares = 100;
        uint256 assetsExpected = 100;
        uint256 lockedRate = 1e18;

        _request(alice, shares, assetsExpected, lockedRate);

        // Rate drops to 0 (extreme slashing: total assets ~= 0).
        uint256 currentRate = 0;

        vm.expectEmit(true, false, false, true, address(queue));
        emit WithdrawalAdjusted(1, assetsExpected, 0);

        vm.expectEmit(true, false, false, true, address(queue));
        emit WithdrawalFinalized(1, 0);

        vm.prank(vault);
        (uint256 used, uint256 finalizedCount, uint256 totalAdjusted) =
            queue.finalizeWithdrawals(assetsExpected, currentRate);

        // Zero-payout request must NOT be counted in used/finalizedCount
        // to preserve the vault invariant (finalizedAmount == 0) == (finalizedCount == 0).
        assertEq(used, 0, "zero-payout request should not consume liquidity");
        assertEq(finalizedCount, 0, "zero-payout request should not count as finalized");
        assertEq(totalAdjusted, assetsExpected, "full original amount should be reported as adjusted");

        // The request itself should be marked finalized in storage so the queue advances.
        IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(1);
        assertTrue(req.finalized, "request should be marked finalized in storage");
        assertEq(req.assetsExpected, 0, "assetsExpected should be adjusted to zero");

        // Queue bookkeeping should be fully cleared.
        assertEq(queue.totalPendingAssets(), 0, "pending assets should be zero");
        assertEq(queue.totalPendingShares(), 0, "pending shares should be zero");
        assertEq(queue.nextPendingId(), 2, "next pending id should advance past the request");
    }

    function test_FinalizeWithdrawals_ZeroPayoutDoesNotBlockSubsequentRequests() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Alice's request will adjust to zero payout; Bob's will adjust to a non-zero payout.
        _request(alice, 100, 100, 1e18);
        _request(bob, 200, 200, 1e18);

        // Rate drops so payout = shares * rate / 1e18.
        // Alice: 100 * 1 / 1e18 = 0 (rounds to zero).
        // Bob:   200 * 1 / 1e18 = 0 (also rounds to zero).
        uint256 currentRate = 1; // near-zero rate

        vm.prank(vault);
        (uint256 used, uint256 finalizedCount, uint256 totalAdjusted) = queue.finalizeWithdrawals(300, currentRate);

        // Both requests adjust to zero, so both finalize via the zero-payout path.
        assertEq(used, 0, "no liquidity should be consumed");
        assertEq(finalizedCount, 0, "no requests should count as finalized");
        assertEq(totalAdjusted, 300, "full amount should be adjusted");

        assertTrue(queue.getRequest(1).finalized, "alice request should be finalized");
        assertTrue(queue.getRequest(2).finalized, "bob request should be finalized");
        assertEq(queue.totalPendingAssets(), 0, "all pending assets should be cleared");
        assertEq(queue.totalPendingShares(), 0, "all pending shares should be cleared");
        assertEq(queue.nextPendingId(), 3, "queue should advance past both requests");
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM REQUESTS
    //////////////////////////////////////////////////////////////*/

    function test_Claim_RevertWhen_NotFinalized() public {
        address alice = makeAddr("alice");
        _request(alice, 100, 100, 1e18);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__NotFinalized.selector, 1));
        vm.prank(vault);
        queue.claimWithdrawal(1);
    }

    function test_Claim_RevertWhen_AlreadyClaimed() public {
        address alice = makeAddr("alice");
        _request(alice, 100, 100, 1e18);

        vm.prank(vault);
        queue.finalizeWithdrawals(200, NO_SLASH_RATE);

        vm.prank(vault);
        queue.claimWithdrawal(1);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__AlreadyClaimed.selector, 1));
        vm.prank(vault);
        queue.claimWithdrawal(1);
    }

    function test_Claim_ReturnsAssetsExpected() public {
        address alice = makeAddr("alice");
        _request(alice, 150, 150, 1e18);

        vm.prank(vault);
        queue.finalizeWithdrawals(200, NO_SLASH_RATE);

        vm.expectEmit(true, true, false, true, address(queue));
        emit WithdrawalClaimed(1, alice, 150);

        vm.prank(vault);
        uint256 assets = queue.claimWithdrawal(1);

        assertEq(assets, 150, "claim should return the expected assets");
        assertEq(queue.totalPendingAssets(), 0, "claim should not change pending totals");
    }

    /*//////////////////////////////////////////////////////////////
                           ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_ClaimWithdrawal_RevertWhen_Unauthorized() public {
        address alice = makeAddr("alice");
        address attacker = makeAddr("attacker");
        _request(alice, 100, 100, 1e18);

        vm.prank(vault);
        queue.finalizeWithdrawals(200, NO_SLASH_RATE);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault.selector, attacker));
        vm.prank(attacker);
        queue.claimWithdrawal(1);
    }

    function test_ClaimWithdrawal_RevertWhen_CalledByAdmin() public {
        address alice = makeAddr("alice");
        _request(alice, 100, 100, 1e18);

        vm.prank(vault);
        queue.finalizeWithdrawals(200, NO_SLASH_RATE);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault.selector, admin));
        vm.prank(admin);
        queue.claimWithdrawal(1);
    }

    function test_ClaimWithdrawal_RevertWhen_CalledByRecipient() public {
        address alice = makeAddr("alice");
        _request(alice, 100, 100, 1e18);

        vm.prank(vault);
        queue.finalizeWithdrawals(200, NO_SLASH_RATE);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault.selector, alice));
        vm.prank(alice);
        queue.claimWithdrawal(1);
    }

    function testFuzz_ClaimWithdrawal_RevertWhen_NotVault(address caller) public {
        vm.assume(caller != vault);

        address alice = makeAddr("alice");
        _request(alice, 100, 100, 1e18);

        vm.prank(vault);
        queue.finalizeWithdrawals(200, NO_SLASH_RATE);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault.selector, caller));
        vm.prank(caller);
        queue.claimWithdrawal(1);
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
            // casting to uint160 is safe because 100 + i stays within 160 bits
            // forge-lint: disable-next-line(unsafe-typecast)
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

        vm.prank(vault);
        (uint256 used, uint256 finalizedCountObserved,) = queue.finalizeWithdrawals(available, NO_SLASH_RATE);

        assertEq(used, expectedUsed, "used assets should match FIFO fill");
        assertEq(finalizedCountObserved, finalizedCount, "finalized count should match FIFO fill");
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

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _request(address user, uint256 shares, uint256 assetsExpected, uint256 rate)
        internal
        returns (uint256 requestId)
    {
        vm.prank(vault);
        requestId = queue.requestWithdrawal(user, shares, assetsExpected, rate);
        return requestId;
    }
}
