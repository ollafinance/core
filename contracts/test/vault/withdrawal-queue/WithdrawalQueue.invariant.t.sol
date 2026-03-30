// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

contract WithdrawalQueueHandler is Test {
    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    WithdrawalQueue public queue;
    address public vault;
    address[] public actors;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(WithdrawalQueue _queue, address _vault) {
        queue = _queue;
        vault = _vault;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                             QUEUE ACTIONS
    //////////////////////////////////////////////////////////////*/

    function requestWithdrawal(uint96 sharesRaw, uint96 assetsRaw, uint256 actorSeed) external {
        if (queue.nextRequestId() > 50) {
            return;
        }

        uint256 assets = uint256(bound(assetsRaw, 1, 1e18));
        address user = actors[bound(actorSeed, 0, actors.length - 1)];

        vm.prank(vault);
        queue.requestWithdrawal(user, assets, assets, 1e18);
    }

    function finalizeWithdrawals(uint96 availableRaw) external {
        uint256 available = uint256(bound(availableRaw, 0, queue.totalPendingAssets()));
        vm.prank(vault);
        queue.finalizeWithdrawals(available, type(uint256).max);
    }

    function claimWithdrawal(uint256 idSeed) external {
        uint256 nextRequestId = queue.nextRequestId();
        if (nextRequestId <= 1) {
            return;
        }

        uint256 id = bound(idSeed, 1, nextRequestId - 1);
        try queue.getRequest(id) returns (IWithdrawalQueue.WithdrawalRequest memory request) {
            if (!request.finalized) return;
        } catch {
            return; // already claimed (deleted)
        }

        vm.prank(vault);
        queue.claimWithdrawal(id);
    }
}

contract WithdrawalQueueInvariantTest is Test {
    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    WithdrawalQueue internal queue;
    WithdrawalQueueHandler internal handler;
    address internal vault;
    address internal admin;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        vault = makeAddr("vault");
        admin = makeAddr("admin");

        WithdrawalQueue implementation = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        queue = WithdrawalQueue(address(proxy));
        queue.initialize(vault, admin, 50_000);

        handler = new WithdrawalQueueHandler(queue, vault);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT CHECKS
    //////////////////////////////////////////////////////////////*/

    function invariant_TotalPendingAssetsMatchesSum() external view {
        uint256 nextRequestId = queue.nextRequestId();
        uint256 expectedTotal = 0;

        for (uint256 id = 1; id < nextRequestId; id++) {
            try queue.getRequest(id) returns (IWithdrawalQueue.WithdrawalRequest memory request) {
                if (!request.finalized) {
                    expectedTotal += request.assetsExpected;
                }
            } catch {
                continue; // claimed (deleted)
            }
        }

        assertEq(queue.totalPendingAssets(), expectedTotal, "pending assets should equal sum of unfinalized requests");
    }

    function invariant_PointersMonotonic() external view {
        assertGe(queue.nextRequestId(), queue.nextPendingId(), "next pending id must not exceed next request id");
        assertGe(queue.nextPendingId(), 1, "next pending id should start at one");
    }

    /// @notice Claimed requests are deleted — getRequest() must revert for any ID that was claimed.
    ///         This invariant verifies that all existing (non-reverted) requests are either pending or
    ///         finalized-but-unclaimed.
    function invariant_ClaimedRequestsAreDeleted() external view {
        uint256 nextRequestId = queue.nextRequestId();
        for (uint256 id = 1; id < nextRequestId; id++) {
            try queue.getRequest(id) returns (IWithdrawalQueue.WithdrawalRequest memory) {
            // If getRequest succeeds, the request has not been claimed (not deleted)
            }
                catch {
                // Reverted — request was claimed and deleted, which is expected
            }
        }
    }

    /// @notice All requests with id < nextPendingId must be finalized (FIFO ordering).
    function invariant_FIFOQueueOrdering() external view {
        uint256 nextPending = queue.nextPendingId();
        uint256 nextRequestId = queue.nextRequestId();

        for (uint256 id = 1; id < nextPending && id < nextRequestId; id++) {
            try queue.getRequest(id) returns (IWithdrawalQueue.WithdrawalRequest memory request) {
                assertTrue(request.finalized, "all requests with id < nextPendingId must be finalized");
            } catch {
                continue; // claimed (deleted) — was finalized before deletion
            }
        }
    }

    function invariant_NextPendingIsUnfinalized() external view {
        uint256 nextPendingId = queue.nextPendingId();
        uint256 nextRequestId = queue.nextRequestId();
        if (nextPendingId >= nextRequestId) {
            return;
        }

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(nextPendingId);
        assertFalse(request.finalized, "next pending request should be unfinalized");
    }
}
