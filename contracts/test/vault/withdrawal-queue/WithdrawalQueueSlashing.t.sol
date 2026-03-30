// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

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
}
