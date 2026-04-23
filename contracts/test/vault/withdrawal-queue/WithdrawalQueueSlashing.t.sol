// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

/// @title WithdrawalQueueSlashingTest
/// @notice Tests exercising the real WithdrawalQueue's slashing adjustment, FIFO blocking,
///         gas threshold loop-breaking, and claim validation. Uses the production contract
///         deployed behind a UUPS proxy, with the test contract itself set as `vault` so
///         that onlyVault functions can be called directly.
contract WithdrawalQueueSlashingTest is Test {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawalFinalized(uint256 indexed id, uint256 assets);
    event WithdrawalAdjusted(uint256 indexed id, uint256 originalAmount, uint256 adjustedAmount);

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    WithdrawalQueue internal queue;
    address internal admin;

    /// @dev Rate passed as currentRate when no slashing adjustment is intended.
    uint256 internal constant NO_SLASH_RATE = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        admin = makeAddr("admin");

        // Deploy real WithdrawalQueue behind UUPS proxy with this test contract as vault
        WithdrawalQueue implementation = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        queue = WithdrawalQueue(address(proxy));
        queue.initialize(address(this), admin, 50_000);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _request(address user, uint256 shares, uint256 assetsExpected, uint256 rate)
        internal
        returns (uint256 requestId)
    {
        requestId = queue.requestWithdrawal(user, shares, assetsExpected, rate);
        return requestId;
    }

    /*//////////////////////////////////////////////////////////////
                      SLASHING ADJUSTMENT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice When currentRate < request.rate, payout is adjusted to shares * currentRate / 1e18.
    function test_WQ_SlashingAdjustment_ReducesPayout() public {
        address alice = makeAddr("alice");
        // Request at rate 1e18: 100 shares => 100 assetsExpected
        _request(alice, 100, 100, 1e18);

        // Slash: currentRate dropped to 0.8e18 (20% drop)
        uint256 currentRate = 0.8e18;

        vm.expectEmit(true, false, false, true, address(queue));
        emit WithdrawalAdjusted(1, 100, 80);

        vm.expectEmit(true, false, false, true, address(queue));
        emit WithdrawalFinalized(1, 80);

        (uint256 used, uint256 finalizedCount, uint256 totalAdjusted) = queue.finalizeWithdrawals(200, currentRate);

        assertEq(used, 80, "used should reflect adjusted payout");
        assertEq(finalizedCount, 1, "one request should be finalized");
        assertEq(totalAdjusted, 20, "adjustment should be original - adjusted");

        IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(1);
        assertTrue(req.finalized, "request should be finalized");
        assertEq(req.assetsExpected, 80, "assetsExpected should be adjusted");
        assertEq(queue.totalPendingAssets(), 0, "pending assets should be zero");
        assertEq(queue.totalPendingShares(), 0, "pending shares should be zero");
    }

    /// @notice When currentRate == request.rate, no adjustment occurs.
    function test_WQ_NoAdjustment_WhenRateEqual() public {
        address alice = makeAddr("alice");
        _request(alice, 100, 100, 1e18);

        (uint256 used, uint256 finalizedCount, uint256 totalAdjusted) = queue.finalizeWithdrawals(200, 1e18);

        assertEq(used, 100, "used should be full amount");
        assertEq(finalizedCount, 1, "one request finalized");
        assertEq(totalAdjusted, 0, "no adjustment when rates equal");

        IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(1);
        assertEq(req.assetsExpected, 100, "assetsExpected should be unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                  PENDING SHARES DECREMENT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice totalPendingShares is decremented correctly on finalization.
    function test_WQ_TotalPendingShares_DecrementedOnFinalize() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _request(alice, 100, 100, 1e18);
        _request(bob, 200, 200, 1e18);

        assertEq(queue.totalPendingShares(), 300, "initial pending shares should be 300");

        // Finalize first request only (150 < 200, so bob's request blocks)
        queue.finalizeWithdrawals(150, NO_SLASH_RATE);

        assertEq(queue.totalPendingShares(), 200, "pending shares should decrease by alice's shares");
        assertEq(queue.totalPendingAssets(), 200, "pending assets should track bob's remaining");
    }

    /*//////////////////////////////////////////////////////////////
                       CLAIM VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claiming an unfinalized request reverts.
    function test_WQ_ClaimUnfinalized_Reverts() public {
        address alice = makeAddr("alice");
        _request(alice, 100, 100, 1e18);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__NotFinalized.selector, 1));
        queue.claimWithdrawal(1);
    }

    /// @notice Double-claiming a finalized request reverts.
    function test_WQ_DoubleClaim_Reverts() public {
        address alice = makeAddr("alice");
        _request(alice, 100, 100, 1e18);

        queue.finalizeWithdrawals(200, NO_SLASH_RATE);

        // First claim succeeds
        uint256 assets = queue.claimWithdrawal(1);
        assertEq(assets, 100, "first claim should return assets");

        // Second claim reverts — request deleted after first claim
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__InvalidRequest.selector, 1));
        queue.claimWithdrawal(1);
    }

    /*//////////////////////////////////////////////////////////////
                       GAS THRESHOLD TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas threshold breaks the finalization loop, producing partial progress.
    function test_WQ_GasThreshold_BreaksLoop() public {
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
        uint256 probedFinalized;
        uint256[5] memory gasOptions = [uint256(80_000), 100_000, 120_000, 160_000, 200_000];

        for (uint256 i = 0; i < gasOptions.length; i++) {
            vm.revertToState(snapshotId);
            (bool success, bytes memory data) = address(queue)
            .call{ gas: gasOptions[i] }(abi.encodeCall(queue.finalizeWithdrawals, (available, NO_SLASH_RATE)));

            if (!success) continue;

            (, uint256 finalizedCandidate,) = abi.decode(data, (uint256, uint256, uint256));
            if (finalizedCandidate > 0 && finalizedCandidate < totalRequests) {
                selectedGas = gasOptions[i];
                probedFinalized = finalizedCandidate;
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial finalization");

        vm.revertToState(snapshotId);
        (uint256 usedObserved, uint256 finalizedCountObserved,) =
            queue.finalizeWithdrawals{ gas: selectedGas }(available, NO_SLASH_RATE);

        assertEq(finalizedCountObserved, probedFinalized, "finalized count should match probe");
        assertGt(finalizedCountObserved, 0, "should finalize at least some requests");
        assertLt(finalizedCountObserved, totalRequests, "should not finalize all requests (gas bounded)");
        assertEq(usedObserved, finalizedCountObserved * assetsExpected, "used should match finalized count");
    }

    /*//////////////////////////////////////////////////////////////
                        FIFO BLOCKING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A large request at the head blocks smaller requests behind it.
    function test_WQ_FIFO_Blocking() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Alice: large request (200 assets)
        _request(alice, 200, 200, 1e18);
        // Bob: small request (50 assets)
        _request(bob, 50, 50, 1e18);

        // Only 150 available -- not enough for alice's 200
        (uint256 used, uint256 finalizedCount,) = queue.finalizeWithdrawals(150, NO_SLASH_RATE);

        assertEq(used, 0, "nothing should be finalized when head request is under-funded");
        assertEq(finalizedCount, 0, "no requests should be finalized");

        IWithdrawalQueue.WithdrawalRequest memory aliceReq = queue.getRequest(1);
        IWithdrawalQueue.WithdrawalRequest memory bobReq = queue.getRequest(2);
        assertFalse(aliceReq.finalized, "alice's request should not be finalized");
        assertFalse(bobReq.finalized, "bob's request should be blocked by alice");
    }

    /*//////////////////////////////////////////////////////////////
                    ZERO-PAYOUT SLASHING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Extreme slashing reduces payout to zero; request finalizes without consuming liquidity.
    function test_WQ_ZeroPayout_AdvancesQueue() public {
        address alice = makeAddr("alice");
        _request(alice, 100, 100, 1e18);

        // Rate dropped to 0 (total slash)
        (uint256 used, uint256 finalizedCount, uint256 totalAdjusted) = queue.finalizeWithdrawals(100, 0);

        assertEq(used, 0, "zero-payout should not consume liquidity");
        assertEq(finalizedCount, 0, "zero-payout should not count as finalized");
        assertEq(totalAdjusted, 100, "full amount should be adjusted");

        IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(1);
        assertTrue(req.finalized, "request should still be marked finalized in storage");
        assertEq(req.assetsExpected, 0, "assetsExpected should be zero");
        assertEq(queue.totalPendingShares(), 0, "pending shares should be cleared");
        assertEq(queue.nextPendingId(), 2, "queue should advance");
    }

    /// @notice A zero-payout request at the head must not consume liquidity; the next request
    ///         behind it should still be finalized with exactly its expected payout. The key
    ///         assertion is that `available` is debited ONLY by the second request.
    function test_WQ_ZeroPayout_FollowedByNormalRequest_OnlyDebitsSecond() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Alice: head request totally slashed at currentRate=0 → payout = 100 * 0 / 1e18 = 0.
        _request(alice, 100, 100, 1e18);
        // Bob: lockedRate = 0 matches the call-time currentRate below, so the adjustment branch
        //      is skipped (currentRate < request.rate is false) and bob keeps his 50 payout.
        _request(bob, 50, 50, 0);

        // available = exactly bob's payout (50). Alice's zero-payout must NOT debit `available`.
        (uint256 used, uint256 finalizedCount, uint256 totalAdjusted) = queue.finalizeWithdrawals(50, 0);

        assertEq(used, 50, "only bob's payout should be debited from available");
        assertEq(finalizedCount, 1, "only bob should count as finalized (alice is zero-payout)");
        assertEq(totalAdjusted, 100, "alice's full 100 counted as adjusted");

        IWithdrawalQueue.WithdrawalRequest memory aliceReq = queue.getRequest(1);
        IWithdrawalQueue.WithdrawalRequest memory bobReq = queue.getRequest(2);
        assertTrue(aliceReq.finalized, "alice should be finalized (zero payout)");
        assertEq(aliceReq.assetsExpected, 0, "alice's assetsExpected written down to zero");
        assertTrue(bobReq.finalized, "bob should be finalized with full payout");
        assertEq(bobReq.assetsExpected, 50, "bob's assetsExpected unchanged");

        assertEq(queue.totalPendingAssets(), 0, "pending assets cleared");
        assertEq(queue.totalPendingShares(), 0, "pending shares cleared");
        assertEq(queue.nextPendingId(), 3, "queue should advance past both requests");
    }

    /*//////////////////////////////////////////////////////////////
              ADJUSTMENT-THEN-UNDERFUND REGRESSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression: when a slashing adjustment is computed for the head request but
    ///         `available` is insufficient to cover the adjusted payout, the loop must break
    ///         WITHOUT persisting any state mutations for that request. The intended behavior
    ///         is that the request remains fully pending (original `assetsExpected` preserved)
    ///         so that a later call with sufficient liquidity — or a recovered rate — can
    ///         finalize it correctly.
    ///
    ///         Today the production contract writes `request.assetsExpected = payout`,
    ///         decrements `pendingAssets`, accrues `totalAdjusted`, and emits
    ///         `WithdrawalAdjusted` BEFORE checking `available < assetsExpected`. If the break
    ///         fires, those writes persist — locking in the adjusted-down payout even though
    ///         no actual finalization occurred. This test asserts the fixed behavior and is
    ///         expected to FAIL against the buggy contract.
    function test_WQ_SlashingAdjustment_UnderfundedHead_DoesNotMutateState() public {
        address alice = makeAddr("alice");
        // Alice: 1000 shares at rate 1e18, assetsExpected=1000
        _request(alice, 1000, 1000, 1e18);

        // Slash: currentRate = 0.5e18 → payout would be 1000 * 0.5e18 / 1e18 = 500
        // Available = 100, which is below both the original (1000) and the would-be adjusted (500).
        uint256 currentRate = 0.5e18;

        // Record logs so we can assert that WithdrawalAdjusted was NOT emitted.
        vm.recordLogs();

        (uint256 used, uint256 finalizedCount, uint256 totalAdjusted) = queue.finalizeWithdrawals(100, currentRate);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 adjustedTopic = keccak256("WithdrawalAdjusted(uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(queue)) continue;
            assertTrue(
                logs[i].topics.length == 0 || logs[i].topics[0] != adjustedTopic,
                "WithdrawalAdjusted must not be emitted when break fires before finalization"
            );
        }

        // Return values: nothing was applied.
        assertEq(used, 0, "used must be zero when the head request is underfunded");
        assertEq(finalizedCount, 0, "no requests should be finalized");
        assertEq(totalAdjusted, 0, "no adjustment should be counted when the request is not finalized");

        // Storage: request still pending and original `assetsExpected` preserved.
        IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(1);
        assertFalse(req.finalized, "request must remain pending when break fires");
        assertEq(req.assetsExpected, 1000, "assetsExpected must NOT be reduced on unapplied adjustment");

        // Queue-wide state: nothing debited.
        assertEq(queue.totalPendingAssets(), 1000, "totalPendingAssets must not be reduced");
        assertEq(queue.totalPendingShares(), 1000, "totalPendingShares must not be reduced");
        assertEq(queue.nextPendingId(), 1, "queue head must not advance");
    }

    /// @notice Regression (downstream): if the adjustment was silently locked in by the prior
    ///         underfunded-break bug, a later call — even with sufficient liquidity AND a
    ///         recovered rate — would pay the user only the written-down amount. This test
    ///         asserts the fixed behavior: after an underfunded break, a subsequent
    ///         `finalizeWithdrawals` call with a recovered rate pays the FULL original
    ///         `assetsExpected`. Expected to FAIL against the buggy contract.
    function test_WQ_SlashingAdjustment_RateRecovery_PreservesOriginalPayout() public {
        address alice = makeAddr("alice");
        _request(alice, 1000, 1000, 1e18);

        // First call: slashed rate + insufficient liquidity → break path.
        queue.finalizeWithdrawals(100, 0.5e18);

        // Second call: rate recovered to the locked rate, plenty of liquidity.
        // No adjustment should trigger; alice should receive her full 1000.
        vm.expectEmit(true, false, false, true, address(queue));
        emit WithdrawalFinalized(1, 1000);

        (uint256 used, uint256 finalizedCount, uint256 totalAdjusted) = queue.finalizeWithdrawals(1000, 1e18);

        assertEq(used, 1000, "user must receive full original payout after rate recovery");
        assertEq(finalizedCount, 1, "request must be finalized on recovery call");
        assertEq(totalAdjusted, 0, "no adjustment should occur when rate has recovered");

        IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(1);
        assertTrue(req.finalized, "request should be finalized after recovery");
        assertEq(req.assetsExpected, 1000, "assetsExpected must remain the original value");
    }
}
