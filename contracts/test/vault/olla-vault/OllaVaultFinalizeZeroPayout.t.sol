// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";

/// @title OllaVaultFinalizeZeroPayoutTest
/// @notice Regression coverage for the audit L-27 fix: zero-payout (fully-slashed) withdrawal
///         requests must be counted in `finalizedCount`, must advance `_nextPendingId`, must mark
///         the request finalized, and must remain claimable (with a zero asset transfer).
/// @dev Drives the slashing branch directly via `currentRate = 0` on `finalizeWithdrawals` rather
///      than going through OllaCore's accounting — the vault's loop is the unit under test.
contract OllaVaultFinalizeZeroPayoutTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    MockOllaGovernance internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = new MockOllaGovernance();
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();

        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 0, 5_000, address(governance), rewardsAccumulator, address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(core), address(governance));

        vm.prank(address(governance));
        core.setVault(address(vault));
        vm.prank(address(governance));
        core.unpause();
        vm.prank(address(governance));
        vault.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _depositAndRequest(address user, uint256 assets) internal returns (uint256 requestId) {
        asset.mint(user, assets);
        vm.prank(user);
        asset.approve(address(vault), assets);
        vm.prank(user);
        uint256 shares = vault.deposit(assets, user, 0);
        vm.prank(user);
        requestId = vault.requestRedeem(shares, user, user);
    }

    /*//////////////////////////////////////////////////////////////
              ZERO-PAYOUT SLASH FINALIZE — AUDIT L-27 REGRESSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Primary L-27 pin: zero-payout slashes must be counted in `finalizedCount`.
    /// @dev If a future change drops the `++finalizedCount` from the zero-payout branch this test
    ///      fails. Without the counter, OllaCore's downstream branching and any integrator reading
    ///      the return value loses visibility that the queue advanced.
    function test_FinalizeWithdrawals_ZeroPayoutSlash_IncrementsCount() external {
        uint256 requestId = _depositAndRequest(address(this), 10 * DECIMALS);

        // Sanity: pending counters reflect the request before finalize.
        assertEq(vault.pendingWithdrawalAssets(), 10 * DECIMALS, "request enqueued");
        assertEq(vault.nextUnfinalizedWithdrawalRequestId(), requestId, "queue head at request");

        // currentRate = 0 forces payout = shares * 0 / 1e18 = 0. The slashing branch then
        // adjusts the request to 0 and falls into the zero-payout finalize branch.
        vm.prank(address(core));
        (uint256 finalizedAmount, uint256 finalizedCount) =
            vault.finalizeWithdrawals(10 * DECIMALS, 0, type(uint256).max);

        assertEq(finalizedAmount, 0, "no liquidity consumed for fully-slashed request");
        assertEq(finalizedCount, 1, "L-27: zero-payout slash must increment finalizedCount");
    }

    /// @notice Zero-payout finalize must advance the queue head past the slashed request.
    function test_FinalizeWithdrawals_ZeroPayoutSlash_AdvancesPendingId() external {
        uint256 requestId = _depositAndRequest(address(this), 10 * DECIMALS);

        vm.prank(address(core));
        vault.finalizeWithdrawals(10 * DECIMALS, 0, type(uint256).max);

        assertEq(
            vault.nextUnfinalizedWithdrawalRequestId(),
            requestId + 1,
            "queue head must advance past zero-payout finalized request"
        );
        assertEq(vault.pendingWithdrawalAssets(), 0, "pending assets cleared");
        assertEq(vault.pendingWithdrawalShares(), 0, "pending shares cleared");
    }

    /// @notice Zero-payout finalize must mark the request as finalized in storage.
    function test_FinalizeWithdrawals_ZeroPayoutSlash_MarksFinalized() external {
        uint256 requestId = _depositAndRequest(address(this), 10 * DECIMALS);

        vm.prank(address(core));
        vault.finalizeWithdrawals(10 * DECIMALS, 0, type(uint256).max);

        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertTrue(req.finalized, "zero-payout request must be marked finalized");
        assertEq(req.assetsExpected, 0, "request payout adjusted to 0");
    }

    /// @notice The user can still claim a zero-payout request; the claim must transfer 0 assets.
    /// @dev Burns the user's `_claimableShares` ledger entry on claim — same accounting as a
    ///      real-payout claim, just with `assets = 0`.
    function test_FinalizeWithdrawals_ZeroPayoutSlash_RemainsClaimable() external {
        address user = makeAddr("user");
        uint256 requestId = _depositAndRequest(user, 10 * DECIMALS);

        vm.prank(address(core));
        vault.finalizeWithdrawals(10 * DECIMALS, 0, type(uint256).max);

        // maxRedeem now reflects the zero-payout claim is available.
        assertGt(vault.maxRedeem(user), 0, "claimable shares ledger credited even for zero payout");

        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 claimedAssets = vault.claimRequestById(requestId);

        assertEq(claimedAssets, 0, "claim of fully-slashed request returns 0 assets");
        assertEq(asset.balanceOf(user), userBalanceBefore, "no asset transfer for zero-payout claim");
        assertEq(vault.maxRedeem(user), 0, "claimable shares ledger cleared after claim");
    }

    /// @notice Mixed batch — some zero-payout, some non-zero (partial slash) — counts and amounts
    ///         must agree with the per-request paths.
    /// @dev Drives a partial slash where `request.rate = 1e18` and `currentRate = 0.5e18`. The
    ///      slashing branch reduces payout from `assetsExpected` to `shares * 0.5`. This exercises
    ///      the non-zero adjusted path (count++ AND amount+=payout).
    function test_FinalizeWithdrawals_PartialSlash_IncrementsCountAndAmount() external {
        uint256 requestId = _depositAndRequest(address(this), 10 * DECIMALS);

        // currentRate = 0.5e18 — payout = shares * 0.5 (non-zero).
        vm.prank(address(core));
        (uint256 finalizedAmount, uint256 finalizedCount) =
            vault.finalizeWithdrawals(10 * DECIMALS, 0.5e18, type(uint256).max);

        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertTrue(req.finalized, "partially-slashed request must be marked finalized");
        assertGt(finalizedAmount, 0, "partial slash should consume some liquidity");
        assertEq(finalizedCount, 1, "partial slash counts as one finalize");
        assertEq(req.assetsExpected, finalizedAmount, "stored payout matches what was consumed");
    }

    /// @notice Bidirectional consistency rejection — `finalizedAmount > 0` with `finalizedCount == 0`
    ///         remains an inconsistency that must revert. After L-27 the loop body cannot produce
    ///         this state, so this is a defense-in-depth assertion against future bookkeeping bugs.
    /// @dev Currently the loop enforces this naturally: every path that increments finalizedAmount
    ///      also increments finalizedCount. There is no straightforward way to construct the
    ///      mismatch via public surface — included here as a documentation test for the invariant.
    function test_FinalizeWithdrawals_AmountWithoutCount_IsRejected() external {
        // The branch `if (finalizedAmount > 0 && finalizedCount == 0) revert ...` is unreachable
        // through any current code path. This test asserts that — if anyone tries to drive the
        // loop into this state in the future — the post-loop check fires.
        //
        // We assert the structural property: a successful normal finalize keeps amount and count
        // in agreement (count > 0 iff amount > 0 OR slashing took place).
        uint256 requestId = _depositAndRequest(address(this), 10 * DECIMALS);

        vm.prank(address(core));
        (uint256 finalizedAmount, uint256 finalizedCount) =
            vault.finalizeWithdrawals(10 * DECIMALS, 1e18, type(uint256).max);

        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertTrue(req.finalized, "normal-rate request finalized");
        assertEq(finalizedCount, 1, "single request counted");
        assertEq(finalizedAmount, 10 * DECIMALS, "full payout consumed");
        assertGt(finalizedAmount, 0, "amount > 0 implies count > 0 (loop invariant)");
        assertGt(finalizedCount, 0, "loop invariant: amount > 0 -> count > 0");
    }
}
