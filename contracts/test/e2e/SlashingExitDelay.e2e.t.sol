// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { E2EBaseWithRealStaking } from "./E2EBaseWithRealStaking.sol";

/// @title SlashingExitDelayE2E
/// @notice Full-pipeline E2E tests exercising slashing with realistic exit delays.
///         The default MockAztecRollup uses immediate exits (exitableAt = block.timestamp),
///         which means most E2E tests never exercise the timing-sensitive paths through
///         the protocol. These tests set a 7-day exit delay and verify:
///
///         1. Normal lifecycle: deposit → stake → redeem → unstake(with delay) → finalize → claim
///         2. Slash during exit delay reduces the tokens received but withdrawal queue adjusts correctly
///         3. Slash on active attester → rate drops → user redeems → unstake with delay → finalize
///         4. Multiple slashes (active + exiting) with withdrawal queue fairness
///         5. Conservative accounting when exit is externally finalized at reduced amount
contract SlashingExitDelayE2E is E2EBaseWithRealStaking {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant EXIT_DELAY = 7 days;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawalAdjusted(uint256 indexed id, uint256 originalAmount, uint256 adjustedAmount);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        _deployFullStack();

        // Add attester keys
        _addKeys(10);

        // Enable realistic exit delay
        mockRollup.setExitDelay(EXIT_DELAY);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the activation threshold (stake per attester).
    function _threshold() internal view returns (uint256) {
        return mockRollup.getActivationThreshold();
    }

    /// @notice Slashes an active attester by reducing its stake on the mock rollup.
    function _slashActiveAttester(address attester, uint256 newStake) internal {
        mockRollup.setStake(attester, newStake, address(stakingManager));
    }

    /// @notice Slashes an exiting attester by reducing its exit amount during the delay.
    function _slashExitingAttester(address attester, uint256 newAmount) internal {
        mockRollup.reduceExitAmount(attester, newAmount);
    }

    /// @notice Unpauses if the safety module triggered a circuit breaker.
    function _unpauseIfNeeded() internal {
        if (safetyModule.isPaused()) {
            vm.prank(address(gov));
            safetyModule.unpause();
        }
    }

    /*//////////////////////////////////////////////////////////////
      TEST 1: NORMAL LIFECYCLE WITH EXIT DELAY (NO SLASHING)
    //////////////////////////////////////////////////////////////*/

    /// @notice Full deposit → stake → redeem → unstake (with delay) → finalize → claim.
    ///         No slashing. Verifies the exit delay does not break the happy path.
    function test_ExitDelay_NormalLifecycle_NoSlashing() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 2;

        // 1. Deposit and stake
        uint256 shares = _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        assertEq(core.accountingState().stakedPrincipal, depositAmount, "all staked");

        // 2. Request redeem
        uint256 requestId = _requestRedeem(alice, shares);
        IOllaVault.WithdrawalRequest memory reqBefore = vault.getWithdrawalRequest(requestId);
        assertEq(reqBefore.assetsExpected, depositAmount, "request at full value");

        // 3. Rebalance → unstake (exits created with delay)
        _warpPastCooldown();
        _rebalance();

        // Exits are NOT yet exitable — refresh should not finalize
        _refreshAttesters();
        assertFalse(stakingManager.hasFinalizedUnstakes(), "exits not yet exitable");

        // 4. Warp past exit delay
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        mockRollup.tick(address(0xdead)); // reset tick

        // 5. Refresh now finalizes the exits
        _refreshAttesters();
        assertTrue(stakingManager.hasFinalizedUnstakes(), "exits should be finalized");

        // 6. Complete rebalance to pull funds and finalize queue
        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 7. Claim — should receive full amount (no slashing)
        IOllaVault.WithdrawalRequest memory reqAfter = vault.getWithdrawalRequest(requestId);
        assertTrue(reqAfter.finalized, "request should be finalized");

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);
        assertEq(claimed, depositAmount, "full amount claimed (no slashing)");
    }

    /*//////////////////////////////////////////////////////////////
      TEST 2: SLASH ACTIVE ATTESTER → RATE DROP → DELAYED EXIT → CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Slash while active → rate drops → user redeems partial → unstake with delay →
    ///         wait → finalize → withdrawal queue adjusts payout → claim at reduced rate.
    function test_ExitDelay_ActiveSlash_ThenDelayedExit_WithdrawalAdjusted() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 2;

        // 1. Two users deposit (1 threshold each)
        uint256 sharesA = _deposit(alice, threshold);
        _deposit(bob, threshold);
        _rebalance();
        _completeRebalance();

        uint256 rateBefore = core.exchangeRate();

        // 2. Slash attester1 by 50% while ACTIVE (reduces total from 2x to 1.5x)
        address attester1 = address(uint160(1));
        _slashActiveAttester(attester1, threshold / 2);

        // 3. Refresh + accounting — rate drops
        _refreshAttesters();
        _warpPastCooldown();
        core.updateAccounting();
        _unpauseIfNeeded();

        uint256 rateAfter = core.exchangeRate();
        assertLt(rateAfter, rateBefore, "rate should drop after active slash");

        // 4. Alice requests redeem of her shares at the reduced rate
        uint256 requestId = _requestRedeem(alice, sharesA);

        // 5. Rebalance → unstake 1 attester to cover Alice's withdrawal
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 6. Warp past exit delay
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        mockRollup.tick(address(0xdead));

        // 7. Refresh to finalize exits + rebalance to pull funds + finalize queue
        _refreshAttesters();
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // May need another cycle
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 8. Withdrawal should now be finalized
        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertTrue(req.finalized, "request finalized after exit delay");

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        // Alice deposited `threshold` but slash reduced the rate, so she gets less
        assertLt(claimed, threshold, "claimed < deposited due to slashing");
        assertGt(claimed, 0, "claimed > 0");
    }

    /*//////////////////////////////////////////////////////////////
      TEST 3: SLASH DURING EXIT DELAY — REDUCED TOKENS RECEIVED
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit → stake → redeem → unstake (with delay) → slash DURING delay →
    ///         finalize at reduced amount → withdrawal queue adjusts → claim.
    function test_ExitDelay_SlashDuringExitDelay_ReducedFinalization() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 2;

        // 1. Deposit and stake
        uint256 shares = _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // 2. Request redeem
        uint256 requestId = _requestRedeem(alice, shares);

        // 3. Rebalance → unstake (creates delayed exits)
        _warpPastCooldown();
        _rebalance();

        // 4. Slash DURING exit delay: reduce both exits by 25%
        address attester1 = address(uint160(1));
        address attester2 = address(uint160(2));
        uint256 reducedAmount = threshold * 3 / 4;

        // Only slash attester1 (attester2 may or may not be exiting)
        if (mockRollup.getExit(attester1).exists) {
            _slashExitingAttester(attester1, reducedAmount);
        }
        if (mockRollup.getExit(attester2).exists) {
            _slashExitingAttester(attester2, reducedAmount);
        }

        // 5. Warp past delay
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        mockRollup.tick(address(0xdead));

        // 6. Refresh finalizes exits at reduced amounts
        _refreshAttesters();

        // 7. Update accounting to reflect the loss
        _warpPastCooldown();
        core.updateAccounting();
        _unpauseIfNeeded();

        // 8. Complete rebalance
        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 9. Verify withdrawal finalized
        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertTrue(req.finalized, "request must be finalized");

        // 10. Claim — user receives less due to slash during exit delay
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        assertLt(claimed, depositAmount, "claimed < deposited due to exit-delay slash");
        assertGt(claimed, 0, "claimed > 0");
    }

    /*//////////////////////////////////////////////////////////////
      TEST 4: MULTI-USER FAIRNESS WITH EXIT DELAY SLASHING
    //////////////////////////////////////////////////////////////*/

    /// @notice Two users deposit equal amounts, both request redeem. Slash during exit delay
    ///         should affect both users proportionally.
    function test_ExitDelay_MultiUserFairness_SlashDuringDelay() external {
        uint256 threshold = _threshold();
        uint256 depositPerUser = threshold;

        // 1. Two users deposit
        uint256 sharesA = _deposit(alice, depositPerUser);
        uint256 sharesB = _deposit(bob, depositPerUser);

        // 2. Stake
        _rebalance();
        _completeRebalance();

        // 3. Both request redeem
        uint256 requestIdA = _requestRedeem(alice, sharesA);
        uint256 requestIdB = _requestRedeem(bob, sharesB);

        // 4. Rebalance → unstake with delay
        _warpPastCooldown();
        _rebalance();

        // 5. Slash during exit delay: reduce exits by 20%
        address attester1 = address(uint160(1));
        address attester2 = address(uint160(2));
        uint256 reduced = threshold * 4 / 5;
        if (mockRollup.getExit(attester1).exists) _slashExitingAttester(attester1, reduced);
        if (mockRollup.getExit(attester2).exists) _slashExitingAttester(attester2, reduced);

        // 6. Warp past delay → finalize → accounting → rebalance
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        mockRollup.tick(address(0xdead));
        _refreshAttesters();

        _warpPastCooldown();
        core.updateAccounting();
        _unpauseIfNeeded();

        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 7. Both requests should be finalized
        IOllaVault.WithdrawalRequest memory reqA = vault.getWithdrawalRequest(requestIdA);
        IOllaVault.WithdrawalRequest memory reqB = vault.getWithdrawalRequest(requestIdB);
        assertTrue(reqA.finalized, "Alice's request finalized");
        assertTrue(reqB.finalized, "Bob's request finalized");

        // 8. Both should get equal adjusted payouts (same deposit, same rate drop)
        assertEq(reqA.assetsExpected, reqB.assetsExpected, "equal deposits = equal adjusted payouts");

        // 9. Each gets less than deposited
        assertLt(reqA.assetsExpected, depositPerUser, "payout adjusted down from slash");
    }

    /*//////////////////////////////////////////////////////////////
      TEST 5: ACTIVE SLASH + EXIT DELAY SLASH (DOUBLE HIT)
    //////////////////////////////////////////////////////////////*/

    /// @notice Slash one attester while active (rate drops), then slash another during exit delay
    ///         (fewer tokens received). Withdrawal queue should reflect both losses.
    function test_ExitDelay_DoubleSlash_ActiveThenExiting() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Deposit and stake 3 attesters
        uint256 shares = _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // 2. Slash attester1 while ACTIVE (50% slash)
        address attester1 = address(uint160(1));
        _slashActiveAttester(attester1, threshold / 2);
        _refreshAttesters();

        // 3. Update accounting — rate drops from active slash
        _warpPastCooldown();
        core.updateAccounting();
        _unpauseIfNeeded();

        core.exchangeRate(); // read to ensure no revert; value checked via claimed amount

        // 4. Alice requests redeem at post-slash rate
        uint256 requestId = _requestRedeem(alice, shares);

        // 5. Rebalance → unstake with delay
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 6. During exit delay, slash attester2's exit by 30%
        address attester2 = address(uint160(2));
        if (mockRollup.getExit(attester2).exists) {
            _slashExitingAttester(attester2, threshold * 7 / 10);
        }

        // 7. Warp past delay → finalize
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        mockRollup.tick(address(0xdead));
        _refreshAttesters();

        // 8. Update accounting — includes the reduced finalization
        _warpPastCooldown();
        core.updateAccounting();
        _unpauseIfNeeded();

        // NOTE: The exit-delay slash does NOT appear in slashingDelta (by design, see
        // StakingManager L595-609). The rate may or may not drop further depending on whether
        // the reduced finalization creates a shortfall visible to accounting. Either way,
        // the protocol does not revert.
        uint256 rateAfterExitSlash = core.exchangeRate();
        assertGt(rateAfterExitSlash, 0, "rate should remain positive after double slash");

        // 9. Complete remaining rebalance cycles
        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 10. Verify withdrawal is finalized
        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertTrue(req.finalized, "request finalized after double slash");

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        // User gets significantly less due to two slashing events
        assertLt(claimed, depositAmount, "claimed < deposited (double slash)");
        assertGt(claimed, 0, "claimed > 0");

        // No tokens stuck anywhere
        assertEq(asset.balanceOf(address(core)), 0, "no tokens stuck in core");
    }

    /*//////////////////////////////////////////////////////////////
      TEST 6: EXIT DELAY WITH NO SLASH — WITHDRAWAL QUEUE NOT BLOCKED
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies the withdrawal queue is not permanently blocked when exits have a delay.
    ///         The queue should finalize once the exit delay passes and funds arrive.
    function test_ExitDelay_WithdrawalQueueNotBlocked() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold;

        // 1. Deposit, stake, request redeem
        uint256 shares = _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        uint256 requestId = _requestRedeem(alice, shares);

        // 2. Rebalance → unstake with delay
        _warpPastCooldown();
        _rebalance();

        // 3. Verify queue is pending (not finalized)
        IOllaVault.WithdrawalRequest memory reqPending = vault.getWithdrawalRequest(requestId);
        assertFalse(reqPending.finalized, "request should be pending during exit delay");

        // 4. Try to complete rebalance — should not finalize queue (no funds yet)
        _completeRebalance();
        reqPending = vault.getWithdrawalRequest(requestId);
        assertFalse(reqPending.finalized, "request still pending - exits not exitable");

        // 5. Warp past delay → finalize exits → complete rebalance
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        mockRollup.tick(address(0xdead));
        _refreshAttesters();

        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 6. Queue should now be finalized
        IOllaVault.WithdrawalRequest memory reqFinal = vault.getWithdrawalRequest(requestId);
        assertTrue(reqFinal.finalized, "request finalized after exit delay passes");

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);
        assertEq(claimed, depositAmount, "full deposit claimed (no slashing)");
    }
}
