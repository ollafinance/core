// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { E2EBaseWithRealStaking } from "./E2EBaseWithRealStaking.sol";

/// @title SlashingWithdrawalImpactE2E
/// @notice E2E: validates the complete slashing lifecycle from rollup slash detection through
///         exchange rate drop, safety module circuit breakers, and withdrawal finalization at reduced rate,
///         using real StakingManager + real RewardsAccumulator + MockAztecRollup.
contract SlashingWithdrawalImpactE2E is E2EBaseWithRealStaking {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event CircuitBreakerTriggered(ISafetyModule.BreakerReason reason);
    event NegativeRewardsPeriod(int256 grossRewardsSigned);
    event WithdrawalAdjusted(uint256 indexed id, uint256 originalAmount, uint256 adjustedAmount);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        _deployFullStack();

        // Set target buffer to 0 so all deposited funds go to staking
        _scheduleAndExecute(
            address(gov), abi.encodeCall(gov.setTargetBufferedAssets, (0)), keccak256("setTargetBufferedAssets-0")
        );

        // Add attester keys
        _addKeys(10);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Simulates slashing on an active attester by reducing its stake on the mock rollup.
    /// @dev This keeps the attester in VALIDATING status (no exit), so StakingManager detects it as slashing.
    function _slashAttester(address attester, uint256 newStake) internal {
        mockRollup.setStake(attester, newStake, address(stakingManager));
    }

    /// @notice Returns the activation threshold (stake per attester).
    function _threshold() internal view returns (uint256) {
        return mockRollup.getActivationThreshold();
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Slashing reduces exchange rate proportionally via real StakingManager slashing detection.
    function test_Slashing_ExchangeRateDrops() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Deposit and stake 3 attesters
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        IOllaCore.AccountingState memory stateBeforeSlash = core.accountingState();
        assertEq(stateBeforeSlash.stakedPrincipal, depositAmount, "All deposited assets staked");
        uint256 rateBefore = core.exchangeRate();

        // 2. Slash attester1 by 50% (reduce from threshold to threshold/2)
        address attester1 = address(uint160(1));
        uint256 slashAmount = threshold / 2;
        _slashAttester(attester1, threshold - slashAmount);

        // 3. Refresh attester state to detect slashing
        _refreshAttesters();

        // 4. Update accounting to apply slashing to exchange rate
        _warpPastCooldown();
        core.updateAccounting();

        // 5. Verify exchange rate dropped
        uint256 rateAfter = core.exchangeRate();
        assertLt(rateAfter, rateBefore, "Exchange rate should drop after slashing");

        // 6. Verify slashing delta reflects the loss
        IOllaCore.AccountingState memory stateAfterSlash = core.accountingState();
        assertEq(stateAfterSlash.slashingDelta, slashAmount, "slashingDelta should reflect slash amount");

        // 7. Verify stakedPrincipal decreased
        assertLt(
            stateAfterSlash.stakedPrincipal,
            stateBeforeSlash.stakedPrincipal,
            "stakedPrincipal should decrease after slash"
        );
    }

    /// @notice SafetyModule triggers auto-pause when exchange rate drops > minRateDropBps threshold.
    function test_Slashing_SafetyModuleTriggersAutoPause() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Deposit and stake
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        assertFalse(safetyModule.isPaused(), "System should not be paused initially");

        // 2. Slash attester by large amount (>5% of total to exceed minRateDropBps=500)
        // Need to slash enough that the rate drop exceeds 5%
        address attester1 = address(uint160(1));
        // Slash 100% of one attester (33% of total) - well above 5% threshold
        _slashAttester(attester1, 0);

        // 3. Refresh and trigger accounting update
        _refreshAttesters();
        _warpPastCooldown();

        // Accounting update should trigger circuit breaker
        core.updateAccounting();

        // 4. Verify system is paused
        assertTrue(safetyModule.isPaused(), "SafetyModule should auto-pause on large rate drop");

        // 5. Verify deposits revert while paused
        asset.mint(bob, 100 * DECIMALS);
        vm.prank(bob);
        asset.approve(address(vault), 100 * DECIMALS);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__SafetyModulePaused.selector));
        vault.deposit(100 * DECIMALS, bob, 0);

        // 6. Guardian unpauses
        vm.prank(address(gov));
        safetyModule.unpause();
        assertFalse(safetyModule.isPaused(), "System should be unpaused after guardian action");

        // 7. Deposits work again after unpause
        vm.prank(bob);
        uint256 shares = vault.deposit(100 * DECIMALS, bob, 0);
        assertGt(shares, 0, "Deposit should succeed after unpause");
    }

    /// @notice Withdrawal finalization uses post-slashing exchange rate, giving user reduced payout.
    function test_Slashing_WithdrawalFinalizationAtReducedRate() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Deposit
        uint256 shares = _deposit(alice, depositAmount);

        // 2. Stake all
        _rebalance();
        _completeRebalance();

        // 3. Request redeem of all shares
        uint256 requestId = _requestRedeem(alice, shares);
        IWithdrawalQueue.WithdrawalRequest memory reqBefore = withdrawalQueue.getRequest(requestId);
        assertEq(reqBefore.assetsExpected, depositAmount, "Request should expect full deposit back");

        // 4. Slash attester1 by 50%
        address attester1 = address(uint160(1));
        uint256 slashAmount = threshold / 2;
        _slashAttester(attester1, threshold - slashAmount);

        // 5. Refresh + update accounting
        _refreshAttesters();
        _warpPastCooldown();

        // The updateAccounting may trigger circuit breaker due to large rate drop
        core.updateAccounting();

        // Unpause if circuit breaker triggered (needed for rebalance to proceed)
        if (safetyModule.isPaused()) {
            vm.prank(address(gov));
            safetyModule.unpause();
        }

        // 6. Rebalance -> unstakes attesters to cover withdrawal
        _warpPastCooldown();
        _rebalance();

        // Refresh to finalize unstakes (MockAztecRollup makes exits immediate)
        _refreshAttesters();

        // Continue rebalance to pull unstaked funds and finalize withdrawals
        _completeRebalance();

        // May need additional rebalance cycles to fully process
        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 7. Check if withdrawal was finalized
        IWithdrawalQueue.WithdrawalRequest memory reqAfter = withdrawalQueue.getRequest(requestId);

        if (reqAfter.finalized) {
            // 8. Claim the withdrawal
            vm.prank(alice);
            uint256 claimed = vault.claimRequestById(requestId);

            // 9. User receives less than deposited due to slashing
            assertLt(claimed, depositAmount, "Claimed amount should be less than deposit due to slashing");
            assertGt(claimed, 0, "Claimed amount should be non-zero");

            // 10. Verify no tokens stuck in contracts
            uint256 coreBalance = asset.balanceOf(address(core));
            assertEq(coreBalance, 0, "No tokens should be stuck in core");
        }
    }

    /// @notice Multi-user withdrawal queue: both users get proportionally reduced payouts after slashing.
    function test_Slashing_MultiUserWithdrawalQueueFairness() external {
        uint256 threshold = _threshold();
        uint256 depositPerUser = threshold; // Each user deposits enough for 1 attester

        // 1. Two users deposit
        uint256 sharesA = _deposit(alice, depositPerUser);
        uint256 sharesB = _deposit(bob, depositPerUser);

        // 2. Stake
        _rebalance();
        _completeRebalance();

        // 3. Both users request redeem (Alice first, Bob second -> FIFO)
        uint256 requestIdA = _requestRedeem(alice, sharesA);
        uint256 requestIdB = _requestRedeem(bob, sharesB);

        // Verify FIFO ordering
        assertLt(requestIdA, requestIdB, "Alice's request should have lower ID (FIFO)");

        uint256 rateAtRequest = withdrawalQueue.getRequest(requestIdA).rate;

        // 4. Slash attester1
        address attester1 = address(uint160(1));
        uint256 slashAmount = threshold / 4; // 25% of one attester
        _slashAttester(attester1, threshold - slashAmount);

        // 5. Refresh + accounting
        _refreshAttesters();
        _warpPastCooldown();
        core.updateAccounting();

        // Unpause if needed
        if (safetyModule.isPaused()) {
            vm.prank(address(gov));
            safetyModule.unpause();
        }

        // 6. Rebalance -> unstake -> finalize queue
        _warpPastCooldown();
        _rebalance();
        _refreshAttesters();
        _completeRebalance();

        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 7. Check withdrawal adjustments
        uint256 rateAfterSlash = core.exchangeRate();

        IWithdrawalQueue.WithdrawalRequest memory reqA = withdrawalQueue.getRequest(requestIdA);
        IWithdrawalQueue.WithdrawalRequest memory reqB = withdrawalQueue.getRequest(requestIdB);

        // Both should have been adjusted if rate dropped
        if (rateAfterSlash < rateAtRequest) {
            // Payouts should be proportionally equal (both had same shares, same rate)
            if (reqA.finalized && reqB.finalized) {
                assertEq(
                    reqA.assetsExpected,
                    reqB.assetsExpected,
                    "Both users should get same adjusted payout (equal deposits)"
                );
            }
        }

        // Verify queue accounting is consistent
        uint256 pendingAssets = withdrawalQueue.totalPendingAssets();
        // If all requests were finalized, pending should be zero
        // If some remain, the buffer should have been exhausted
        if (pendingAssets > 0) {
            assertEq(vault.bufferedAssets(), 0, "Buffer should be exhausted if requests still pending");
        }
    }

    /// @notice Slashing during a pending unstake: only the slashed attester affects slashingDelta.
    function test_Slashing_DuringPendingUnstake() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Stake 3 attesters
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // 2. Request a redemption to trigger unstake of 1 attester
        uint256 oneAttesterShares = stAztec.balanceOf(alice) / 3;
        _requestRedeem(alice, oneAttesterShares);

        // 3. Start rebalance to initiate unstake
        _warpPastCooldown();
        _rebalance();

        // At this point, one attester should be in the process of unstaking
        // 4. Now slash a DIFFERENT attester (not the one being unstaked)
        // Attester 1 was likely unstaked, so slash attester 2
        address attester2 = address(uint160(2));
        uint256 slashAmount = threshold / 2;
        _slashAttester(attester2, threshold - slashAmount);

        // 5. Refresh all attesters
        _refreshAttesters();

        // 6. Complete the rebalance
        _completeRebalance();

        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 7. Verify slashing delta only reflects the slashed attester
        IOllaCore.AccountingState memory state = core.accountingState();
        assertEq(state.slashingDelta, slashAmount, "Slashing delta should only reflect the slashed attester");
    }

    /// @notice When slashing loss exceeds reward income, net rewards are negative and no fees are minted.
    function test_Slashing_NegativeNetRewards() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Deposit and stake
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // 2. Accrue small rewards
        uint256 rewardAmount = 50 * DECIMALS;
        mockRollup.addRewards(address(rewardsAccumulator), rewardAmount);

        // Harvest rewards first
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        uint256 treasurySharesBefore = stAztec.balanceOf(treasury);
        uint256 providerSharesBefore = stAztec.balanceOf(providerRewards);
        uint256 rateBefore = core.exchangeRate();

        // 3. Slash an attester by much more than reward income (100% of one attester >> 50 AZTEC rewards)
        address attester1 = address(uint160(1));
        _slashAttester(attester1, 0);

        // 4. Refresh and rebalance
        _refreshAttesters();
        _warpPastCooldown();

        // Record logs to capture NegativeRewardsPeriod event
        vm.recordLogs();
        core.updateAccounting();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // 5. Check for NegativeRewardsPeriod event
        bytes32 negRewardsTopic = NegativeRewardsPeriod.selector;
        bool foundNegativeRewards = false;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(core) && entries[i].topics[0] == negRewardsTopic) {
                int256 grossRewardsSigned = abi.decode(entries[i].data, (int256));
                assertLt(grossRewardsSigned, 0, "Gross rewards should be negative");
                foundNegativeRewards = true;
            }
        }
        assertTrue(foundNegativeRewards, "NegativeRewardsPeriod event should be emitted");

        // 6. No fee shares minted on net loss
        uint256 treasurySharesAfter = stAztec.balanceOf(treasury);
        uint256 providerSharesAfter = stAztec.balanceOf(providerRewards);
        assertEq(treasurySharesAfter, treasurySharesBefore, "No treasury shares on net loss");
        assertEq(providerSharesAfter, providerSharesBefore, "No provider shares on net loss");

        // 7. Exchange rate dropped despite prior reward income
        uint256 rateAfter = core.exchangeRate();
        assertLt(rateAfter, rateBefore, "Exchange rate should drop despite prior rewards");
    }

    /// @notice Circuit breaker cascade: slash -> pause -> unpause -> slash again -> pause -> unpause -> recovery.
    function test_Slashing_CascadeCircuitBreaker_ThenRecovery() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Deposit and stake
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        uint256 rateInitial = core.exchangeRate();

        // --- First slash & circuit breaker ---

        // 2. Slash attester1 by 50% (triggers >5% rate drop)
        address attester1 = address(uint160(1));
        _slashAttester(attester1, threshold / 2);
        _refreshAttesters();

        _warpPastCooldown();
        core.updateAccounting();

        // 3. Verify first pause
        assertTrue(safetyModule.isPaused(), "System should pause after first slash");

        uint256 rateAfterSlash1 = core.exchangeRate();
        assertLt(rateAfterSlash1, rateInitial, "Rate should drop after first slash");

        // 4. Guardian unpauses
        vm.prank(address(gov));
        safetyModule.unpause();
        assertFalse(safetyModule.isPaused(), "System should be unpaused after guardian action");

        // --- Second slash & circuit breaker ---

        // 5. Slash attester2 by 50% (another >5% drop relative to current state)
        address attester2 = address(uint160(2));
        _slashAttester(attester2, threshold / 2);
        _refreshAttesters();

        _warpPastCooldown();
        core.updateAccounting();

        // 6. Verify second pause
        assertTrue(safetyModule.isPaused(), "System should pause after second slash");

        uint256 rateAfterSlash2 = core.exchangeRate();
        assertLt(rateAfterSlash2, rateAfterSlash1, "Rate should drop further after second slash");

        // 7. Guardian unpauses again
        vm.prank(address(gov));
        safetyModule.unpause();
        assertFalse(safetyModule.isPaused(), "System should be unpaused after second guardian action");

        // --- Recovery ---

        // 8. Verify system is stable: exchange rate is still positive after partial slashes
        uint256 rateAfterRecovery = core.exchangeRate();
        assertGt(rateAfterRecovery, 0, "Exchange rate should be positive after partial slashes");

        // 9. New deposits work with the reduced exchange rate
        uint256 newShares = _deposit(bob, threshold);
        assertGt(newShares, 0, "Deposits should work after recovery");

        // Bob gets more shares per asset since the rate dropped
        assertGt(newShares, threshold, "Bob should get more shares than assets due to reduced rate");

        // Bob's shares should be worth approximately what he deposited
        uint256 bobAssetValue = core.convertToAssets(newShares);
        assertApproxEqRel(bobAssetValue, threshold, 0.01e18, "Bob's shares should be worth ~deposit amount");
    }

    /// @notice External exit detection: StakingManager detects externally-initiated exit and updates state.
    /// @dev Covers _exitingCount-- path (line 384) and external exit handling (line 529-540).
    ///      After fix: slashingDelta now tracks the loss from external exits too
    ///      (difference between original stake and the exit recovery amount).
    function test_Slashing_ExternalExitDetection() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Stake 3 attesters
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        uint256 totalStakedBefore = core.accountingState().stakedPrincipal;
        assertEq(totalStakedBefore, depositAmount, "All 3 attesters should be fully staked");

        // 2. Simulate external exit with partial recovery (e.g., slashed then exited by rollup)
        address attester1 = address(uint160(1));
        uint256 recoveredAmount = threshold * 3 / 4; // 75% recovery (25% slashed)
        uint256 expectedSlashLoss = threshold - recoveredAmount; // 25% of one attester's stake
        mockRollup.setExternalExit(attester1, recoveredAmount, block.timestamp);

        // 3. Refresh attester state - detects zombie exit, claims it, transitions to Exiting
        _refreshAttesters();

        // 4. Sync accounting so core sees the updated slashingDelta from StakingManager
        _warpPastCooldown();
        core.updateAccounting();

        // 5. Verify StakingManager detected the external exit and tracked the slashing loss
        uint256 slashingDelta = core.accountingState().slashingDelta;
        assertEq(slashingDelta, expectedSlashLoss, "External exit loss should be tracked in slashingDelta");

        // 6. Complete rebalance to pull unstaked funds from the finalized exit
        _warpPastCooldown();
        _rebalance();

        // Refresh again to finalize the exit (exit is already exitable at block.timestamp)
        _refreshAttesters();
        _completeRebalance();

        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 7. Verify accounting reflects the reduced total staked
        IOllaCore.AccountingState memory stateAfter = core.accountingState();

        // stakedPrincipal should decrease: 2 remaining attesters + whatever came through claims
        // The 3rd attester's exit (recoveredAmount) should have been pulled and added to buffer
        assertLt(stateAfter.stakedPrincipal, totalStakedBefore, "stakedPrincipal should decrease");

        // 8. Verify vault received the recovered funds
        uint256 totalVaultBalance = asset.balanceOf(address(vault));
        assertGt(totalVaultBalance, 0, "Vault should hold recovered funds");

        // 9. Exchange rate should reflect the loss (25% of one attester's stake is gone)
        uint256 rateAfter = core.exchangeRate();
        assertLt(rateAfter, 1e18, "Exchange rate should be below 1:1 due to partial loss");
    }

    /// @notice Verify the _exitingCount decrement path (StakingManager line 384) during slash processing.
    function test_Slashing_ExitingCountDecrement() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 2;

        // 1. Stake 2 attesters
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // 2. Request redeem to trigger unstake of 1 attester
        uint256 halfShares = stAztec.balanceOf(alice) / 2;
        _requestRedeem(alice, halfShares);

        // 3. Start rebalance to initiate the unstake
        _warpPastCooldown();
        _rebalance();

        // Attester should now be in Exiting state on StakingManager
        // 4. Refresh to finalize the exit (MockAztecRollup makes exits immediate)
        _refreshAttesters();

        // This refresh should: detect the exitable exit -> finalize it -> _removeAttester
        // _removeAttester for Exiting attester hits line 384 (_exitingCount--)

        // 5. Complete the rebalance cycle
        _completeRebalance();

        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 6. Verify the system is in a clean state
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "Rebalance should be complete");

        // No tokens should be stuck
        uint256 coreBalance = asset.balanceOf(address(core));
        assertEq(coreBalance, 0, "No tokens should be stuck in core after exit finalization");
    }
}
