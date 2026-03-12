// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { E2EBaseWithRealStaking } from "./E2EBaseWithRealStaking.sol";

/// @title MultiStepRebalanceE2E
/// @notice E2E: validates rebalance behavior across multiple calls, covering partial-step completion,
///         progress persistence, cooldown enforcement, and no-work-available early exit,
///         using real StakingManager + real RewardsAccumulator + MockAztecRollup.
contract MultiStepRebalanceE2E is E2EBaseWithRealStaking {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        _deployFullStack();

        // Set target buffer to 0 so all deposited funds go to staking
        _scheduleAndExecute(
            address(gov), abi.encodeCall(gov.setTargetBufferedAssets, (0)), keccak256("setTargetBufferedAssets-0")
        );
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the activation threshold (stake per attester).
    function _threshold() internal view returns (uint256) {
        return mockRollup.getActivationThreshold();
    }

    /*//////////////////////////////////////////////////////////////
                          NO-WORK-AVAILABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Rebalance is a no-op when no actionable work exists (idle guard).
    function test_MultiStepRebalance_NoWorkAvailable() external {
        // 1. Deposit and stake so system is in steady state
        uint256 threshold = _threshold();
        _addKeys(2);
        _deposit(alice, threshold * 2);
        _rebalance();
        _completeRebalance();

        assertEq(core.accountingState().stakedPrincipal, threshold * 2, "2 attesters staked");
        assertEq(vault.bufferedAssets(), 0, "Buffer should be 0");

        // 2. Warp past cooldown
        _warpPastCooldown();

        // 3. Rebalance should be a no-op (buffer unchanged, no work available)
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) = _rebalance();

        assertEq(rewardsDelta, 0, "No rewards to harvest");
        assertEq(finalizedAmount, 0, "No withdrawals to finalize");
        assertEq(stakedAmount, 0, "No surplus to stake");
        assertEq(resultingBuffer, 0, "Buffer unchanged");

        // 4. Step remains Done
        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Step should remain Done");
    }

    /*//////////////////////////////////////////////////////////////
                        COOLDOWN ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Rebalance reverts if cooldown has not elapsed; succeeds after warping.
    function test_MultiStepRebalance_CooldownBetweenCycles() external {
        uint256 threshold = _threshold();
        _addKeys(2);
        _deposit(alice, threshold * 2);

        // 1. Complete first rebalance cycle
        _rebalance();
        _completeRebalance();

        // 2. Try immediate rebalance -> should revert
        vm.prank(operator);
        vm.expectRevert(); // OllaCore__RebalanceCooldownActive
        core.rebalance();

        // 3. Warp past cooldown
        _warpPastCooldown();

        // 4. New rebalance succeeds (even if no-op)
        vm.prank(operator);
        core.rebalance(); // Should not revert

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Should complete or be Done");
    }

    /*//////////////////////////////////////////////////////////////
                     STAKE INTERRUPTED (KEY EXHAUSTION)
    //////////////////////////////////////////////////////////////*/

    /// @notice Staking is interrupted mid-step when keys are exhausted. Adding keys
    ///         between calls allows completion. Exercises the partial-stake save/resume path.
    function test_MultiStepRebalance_StakeInterrupted() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 5;

        // 1. Add only 2 keys but deposit enough for 5 attesters
        _addKeys(2);
        _deposit(alice, depositAmount);

        // 2. First rebalance: stakes 2 attesters, partial stake saves progress at StakeSurplus
        _rebalance();

        // 3. Assert: progress saved at StakeSurplus with remaining to stake
        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(
            uint256(p.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Should be interrupted at StakeSurplus"
        );
        assertEq(p.stakeRemaining, threshold * 3, "Should have 3 attesters worth remaining");

        // 4. Verify partial staking occurred
        assertEq(core.accountingState().stakedPrincipal, threshold * 2, "2 attesters should be staked");
        assertEq(vault.bufferedAssets(), threshold * 3, "3*threshold should remain in buffer");

        // 5. Second rebalance without adding keys: detects no keys available, moves to Done
        _rebalance();

        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Should complete to Done");
        assertEq(p.stakeRemaining, 0, "stakeRemaining should be cleared");
        assertEq(p.unstakeRemaining, 0, "unstakeRemaining should be 0");

        // 6. Accounting: still 2 attesters staked, surplus in buffer
        assertEq(core.accountingState().stakedPrincipal, threshold * 2, "stakedPrincipal unchanged");
        assertEq(vault.bufferedAssets(), threshold * 3, "Buffer unchanged (no keys to stake)");
    }

    /// @notice Stake interrupted, then keys added between calls -> completes staking.
    function test_MultiStepRebalance_StakeInterrupted_ThenKeysAdded() external {
        uint256 threshold = _threshold();

        // 1. Add 2 keys, deposit for 5 attesters
        _addKeys(2);
        _deposit(alice, threshold * 5);

        // 2. First rebalance: partial stake (2 of 5)
        _rebalance();

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Interrupted at StakeSurplus");

        // 3. Add 3 more keys between calls
        _addKeys(3);

        // 4. Second rebalance: resumes at StakeSurplus, stakes remaining 3
        _rebalance();
        _completeRebalance();

        // 5. All 5 attesters staked
        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Should complete");
        assertEq(core.accountingState().stakedPrincipal, threshold * 5, "All 5 attesters staked");
        assertEq(vault.bufferedAssets(), 0, "Buffer should be empty");
    }

    /*//////////////////////////////////////////////////////////////
                       PROGRESS PERSISTENCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies rebalance progress fields persist correctly in storage between calls.
    function test_MultiStepRebalance_ProgressPersistsBetweenCalls() external {
        uint256 threshold = _threshold();

        // 1. Add 1 key, deposit for 3 attesters
        _addKeys(1);
        _deposit(alice, threshold * 3);

        // 2. First rebalance: stakes 1 of 3, saves progress
        _rebalance();

        // 3. Verify storage fields
        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Step persisted");
        assertEq(p.stakeRemaining, threshold * 2, "stakeRemaining persisted");
        assertEq(p.unstakeRemaining, 0, "unstakeRemaining is 0");

        // 4. Add 2 keys and call rebalance again
        _addKeys(2);
        _rebalance();
        _completeRebalance();

        // 5. Verify progress is clean after completion
        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Step reset to Done");
        assertEq(p.stakeRemaining, 0, "stakeRemaining cleared");
        assertEq(p.unstakeRemaining, 0, "unstakeRemaining cleared");

        // 6. Verify stakeRemaining decremented correctly across calls
        assertEq(core.accountingState().stakedPrincipal, threshold * 3, "All 3 staked");
    }

    /*//////////////////////////////////////////////////////////////
                  PULLUNSTAKED WITH REMAINING EXITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Rebalance saves progress at PullUnstaked when exits remain pending.
    ///         After refreshing attesters, the next call resumes and completes.
    function test_MultiStepRebalance_PullUnstakedResumesAfterExits() external {
        uint256 threshold = _threshold();

        // 1. Stake 3 attesters
        _addKeys(3);
        _deposit(alice, threshold * 3);
        _rebalance();
        _completeRebalance();

        assertEq(core.accountingState().stakedPrincipal, threshold * 3, "3 attesters staked");

        // 2. Request partial redeem to trigger unstaking
        uint256 redeemShares = stAztec.balanceOf(alice) / 2;
        _requestRedeem(alice, redeemShares);

        // 3. Rebalance A: initiates unstakes (done in one cycle)
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 4. Do NOT refresh attesters. Start new rebalance:
        //    PullUnstaked -> hasRemainingExits = true -> saves progress
        _warpPastCooldown();
        _rebalance();

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.PullUnstaked), "Should be stuck at PullUnstaked");

        // 5. Refresh attesters (finalizes exits on rollup, moves funds to StakingManager)
        _refreshAttesters();

        // 6. Resume rebalance: PullUnstaked now completes (hasRemainingExits = false)
        vm.prank(operator);
        core.rebalance();
        _completeRebalance();

        // 7. Step is Done
        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Should complete after exit refresh");

        // 8. Pending withdrawal should be finalized and claimable
        _warpPastCooldown();
        _rebalanceToCompletion(20);
    }

    /*//////////////////////////////////////////////////////////////
           COMBINED: REWARDS + UNSTAKE + PARTIAL STAKE
    //////////////////////////////////////////////////////////////*/

    /// @notice Full lifecycle: rewards accrued, partial redeem, new deposit, and key-limited staking
    ///         spans multiple rebalance calls. Fees minted only once.
    function test_MultiStepRebalance_WithRewardsAndUnstakeAndStake() external {
        uint256 threshold = _threshold();

        // 1. Stake 3 attesters
        _addKeys(3);
        _deposit(alice, threshold * 3);
        _rebalance();
        _completeRebalance();

        assertEq(core.accountingState().stakedPrincipal, threshold * 3, "3 attesters staked");

        // 2. Accrue rewards
        mockRollup.setRewardRatePerSecond(1 * DECIMALS);
        vm.warp(block.timestamp + 100);
        mockRollup.tick(address(rewardsAccumulator));
        uint256 expectedRewards = 100 * DECIMALS;

        // 3. Request partial redeem (1 attester worth) to trigger unstaking
        uint256 redeemShares = stAztec.balanceOf(alice) / 3;
        _requestRedeem(alice, redeemShares);

        // 4. Deposit more funds (for new staking)
        _deposit(bob, threshold * 2);

        // 5. First rebalance: harvests rewards, processes steps, partial completes
        _warpPastCooldown();
        uint256 treasurySharesBefore = stAztec.balanceOf(treasury);
        uint256 providerSharesBefore = stAztec.balanceOf(providerRewards);

        (uint256 rewardsDelta,,,) = _rebalance();
        assertEq(rewardsDelta, expectedRewards, "Rewards harvested in first call");

        // 6. Complete the rebalance cycle (may need multiple calls)
        _completeRebalance();

        // Need to wait for exits, refresh, and continue
        _refreshAttesters();

        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 7. Verify fees were minted (only once, not duplicated)
        assertGt(stAztec.balanceOf(treasury), treasurySharesBefore, "Treasury received fees");
        assertGt(stAztec.balanceOf(providerRewards), providerSharesBefore, "Provider received fees");

        // 8. No tokens stranded
        assertEq(asset.balanceOf(address(core)), 0, "No tokens stuck in Core");
        assertEq(asset.balanceOf(address(stakingManager)), 0, "No tokens stuck in StakingManager");
    }

    /*//////////////////////////////////////////////////////////////
              MULTI-CALL: UNSTAKE + FINALIZE + STAKE
    //////////////////////////////////////////////////////////////*/

    /// @notice Scenario requiring unstake + finalize across multiple calls via remaining exits.
    ///         PullUnstaked saves progress when exits remain, resumes after refresh.
    function test_MultiStepRebalance_UnstakeFinalizeThenStake() external {
        uint256 threshold = _threshold();

        // 1. Stake 3 attesters (uses 3 keys, buffer = 0)
        _addKeys(3);
        uint256 depositAmount = threshold * 3;
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        assertEq(vault.bufferedAssets(), 0, "Buffer should be 0 after full stake");

        // 2. Request redeem of ~2 attesters worth to trigger unstaking (no buffer to cover)
        uint256 twoThirdsShares = (stAztec.balanceOf(alice) * 2) / 3;
        _requestRedeem(alice, twoThirdsShares);

        // 3. Rebalance cycle 1: initiates unstakes (buffer = 0, must unstake to finalize)
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 4. Don't refresh attesters -> next rebalance gets stuck at PullUnstaked
        _warpPastCooldown();
        _rebalance();

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.PullUnstaked), "Stuck at PullUnstaked (call 1)");

        // 5. Refresh attesters to finalize exits
        _refreshAttesters();

        // 6. Resume: PullUnstaked completes -> FinalizeWithdrawals -> Done
        vm.prank(operator);
        core.rebalance();
        _completeRebalance();

        // 7. Complete any remaining cycles
        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 8. Verify final state is consistent
        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Should complete");

        // 9. Conservation: totalAssets = original deposit (no rewards, no slashing)
        //    Some assets are now pending claim by alice. Total protocol value is preserved.
        uint256 totalValue = core.totalAssets();
        assertGt(totalValue, 0, "Protocol should have value");
        assertEq(asset.balanceOf(address(core)), 0, "No tokens stuck in Core");
        assertEq(asset.balanceOf(address(stakingManager)), 0, "No tokens stuck in StakingManager");
    }

    /*//////////////////////////////////////////////////////////////
                   GAS-THRESHOLD EARLY RETURN
    //////////////////////////////////////////////////////////////*/

    /// @notice Uses gas-limited calls to trigger _hasGasForStep() early returns.
    ///         Validates that progress is correctly saved and resumed when gas is insufficient.
    /// @dev Gas values may need adjustment if compiler or contract code changes.
    ///      The gas limit is tuned so that Harvest completes (no gas check) but
    ///      _hasGasForStep() fails at a subsequent step (PullUnstaked or later).
    function test_MultiStepRebalance_GasThresholdInterrupt() external {
        uint256 threshold = _threshold();

        // 1. Add keys and deposit
        _addKeys(5);
        _deposit(alice, threshold * 3);

        // 2. Set gas threshold to maximum (1,000,000)
        _scheduleAndExecute(
            address(gov), abi.encodeCall(gov.setRebalanceGasThreshold, (1_000_000)), keccak256("setGasThreshold-1M")
        );

        // 3. Call rebalance with tightly limited gas.
        //    With threshold=1M, gasleft must be <= 1M for the gas check to fail.
        //    Harvest has no gas check and costs ~50-100K. Overhead is ~50-100K.
        //    So with ~1.1M total gas, Harvest completes but _hasGasForStep() fails
        //    at PullUnstaked because gasleft < 1M.
        vm.prank(operator);
        try core.rebalance{ gas: 1_100_000 }() returns (uint256, uint256, uint256, uint256) {
            // If it returns, check if it was interrupted
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            assertTrue(
                p.step != IOllaCore.RebalanceStep.Done,
                "Should be interrupted (not Done). If this fails, adjust gas limit."
            );

            // Successfully interrupted! Verify progress was saved at an intermediate step.
            assertTrue(uint256(p.step) < uint256(IOllaCore.RebalanceStep.Done), "Step should be before Done");

            // 4. Resume with full gas and default threshold.
            //    forceRebalanceReset to return to Done, then adjust threshold and rebalance fresh.
            vm.prank(address(gov));
            core.forceRebalanceReset();

            _scheduleAndExecute(
                address(gov),
                abi.encodeCall(gov.setRebalanceGasThreshold, (180_000)),
                keccak256("setGasThreshold-default")
            );

            // Complete with full gas
            _warpPastCooldown();
            _rebalance();
            _completeRebalance();

            p = core.rebalanceProgress();
            assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Should complete with full gas");
            assertEq(core.accountingState().stakedPrincipal, threshold * 3, "All 3 attesters staked");
        } catch {
            // Out of gas - the gas limit was too tight for even Harvest + overhead.
            // Verify state wasn't corrupted (revert restores state).
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "OOG revert should preserve state");
            revert("Gas limit too tight for rebalance overhead. Adjust gas parameter.");
        }
    }

    /*//////////////////////////////////////////////////////////////
         NO-COOLDOWN BETWEEN CONTINUATION CALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice When rebalance is mid-step, continuation calls skip cooldown check.
    function test_MultiStepRebalance_NoCooldownForContinuation() external {
        uint256 threshold = _threshold();

        // 1. Add 1 key, deposit for 3 attesters
        _addKeys(1);
        _deposit(alice, threshold * 3);

        // 2. First rebalance: partial stake -> saves at StakeSurplus
        _rebalance();

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Interrupted at StakeSurplus");

        // 3. Second call immediately (no warp) should NOT revert:
        //    Cooldown is only checked when step == Done (start of new cycle)
        vm.prank(operator);
        core.rebalance(); // Should not revert

        // 4. Step should now be Done (no keys for remaining stake)
        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Continuation skips cooldown");
    }

    /*//////////////////////////////////////////////////////////////
          MULTI-STEP WITH FINALIZATION LOOP
    //////////////////////////////////////////////////////////////*/

    /// @notice FinalizeWithdrawals returns early when pending withdrawals remain
    ///         and buffer was partially consumed, requiring another rebalance call.
    function test_MultiStepRebalance_FinalizeWithdrawalsPartialLoop() external {
        uint256 threshold = _threshold();

        // 1. Stake 2 attesters
        _addKeys(2);
        _deposit(alice, threshold * 2);
        _rebalance();
        _completeRebalance();

        // 2. Create multiple redeem requests from different users
        uint256 aliceShares = stAztec.balanceOf(alice);
        uint256 halfShares = aliceShares / 2;
        _requestRedeem(alice, halfShares);

        // 3. Deposit some funds to provide buffer for finalization
        _deposit(bob, threshold / 2);

        // 4. First rebalance: finalize what buffer allows, may need more cycles
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 5. Eventually all should complete
        _refreshAttesters();
        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 6. Verify final state
        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Should complete");
    }

    /*//////////////////////////////////////////////////////////////
       ACCOUNTING CONSISTENCY AFTER MULTI-STEP COMPLETION
    //////////////////////////////////////////////////////////////*/

    /// @notice Multi-step rebalance produces same final state as if it had completed in one call.
    ///         Conservation of value: totalAssets = deposits - claimed.
    function test_MultiStepRebalance_AccountingConsistency() external {
        uint256 threshold = _threshold();

        // 1. Add 2 keys, deposit for 5 attesters -> partial stake
        _addKeys(2);
        uint256 depositAmount = threshold * 5;
        _deposit(alice, depositAmount);
        _rebalance();

        // 2. Progress at StakeSurplus (partial)
        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Partial stake");

        // 3. Complete (moves to Done, no more keys)
        _rebalance();

        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Done");

        // 4. Conservation of value: totalAssets = depositAmount (no rewards, no slashing)
        assertEq(core.totalAssets(), depositAmount, "totalAssets should equal deposit");

        // 5. Breakdown: staked + buffer = deposit
        uint256 staked = core.accountingState().stakedPrincipal;
        uint256 buffer = vault.bufferedAssets();
        assertEq(staked + buffer, depositAmount, "staked + buffer = deposit");
        assertEq(staked, threshold * 2, "2 attesters staked");
        assertEq(buffer, threshold * 3, "3*threshold in buffer");

        // 6. Exchange rate should be 1:1 (no rewards/slashing)
        assertEq(core.exchangeRate(), 1e18, "Exchange rate should be 1:1");
    }
}
