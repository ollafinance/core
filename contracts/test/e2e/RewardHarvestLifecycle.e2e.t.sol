// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { E2EBaseWithRealStaking } from "./E2EBaseWithRealStaking.sol";

/// @title RewardHarvestLifecycleE2E
/// @notice E2E: validates the complete reward flow from rollup accrual through fee distribution,
///         using real StakingManager + real RewardsAccumulator + MockAztecRollup.
contract RewardHarvestLifecycleE2E is E2EBaseWithRealStaking {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardsDelta(uint256 rewardsDelta);
    event RewardsHarvested(uint256 harvested);
    event RewardsRecorded(uint256 balanceDelta);
    event RewardsWithdrawn(uint256 amount);
    event RewardsAccumulatorFundsPulled(uint256 amount);
    event RewardsHarvestFailed(bytes reason);
    event OllaProtocolFeesPaid(uint256 protocolFeeAssets, uint256 treasuryShares, uint256 providerShares);
    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        _deployFullStack();

        // Configure reward rate on mock rollup: 1 AZTEC per second
        mockRollup.setRewardRatePerSecond(1 * DECIMALS);

        // Add attester keys
        _addKeys(10);
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Full lifecycle: deposit -> stake -> accrue rewards -> harvest -> verify token chain
    function test_RewardHarvest_FullLifecycle() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 numAttesters = 3;
        uint256 depositAmount = activationThreshold * numAttesters;

        // 1. Deposit enough for 3 attesters
        _deposit(alice, depositAmount);
        assertEq(vault.bufferedAssets(), depositAmount, "Initial buffer = deposit");

        // 2. Rebalance -> stakes 3 attesters
        _rebalance();
        _completeRebalance();

        IOllaCore.AccountingState memory stateAfterStake = core.accountingState();
        assertEq(stateAfterStake.stakedPrincipal, depositAmount, "All deposited assets staked");
        assertEq(vault.bufferedAssets(), 0, "Buffer should be 0 after full stake");

        // 3. Accrue rewards over 100 seconds via tick()
        uint256 rewardDuration = 100;
        vm.warp(block.timestamp + rewardDuration);
        mockRollup.tick(address(rewardsAccumulator));
        uint256 expectedRewards = 1 * DECIMALS * rewardDuration; // 100 AZTEC

        uint256 pendingRewards = mockRollup.pendingRewards(address(rewardsAccumulator));
        assertEq(pendingRewards, expectedRewards, "Rollup should have accrued rewards");

        // 4. Rebalance again -> triggers harvest
        _warpPastCooldown();

        uint256 vaultBufferBefore = vault.bufferedAssets();
        uint256 treasurySharesBefore = stAztec.balanceOf(treasury);
        uint256 providerSharesBefore = stAztec.balanceOf(providerRewards);

        (uint256 rewardsDelta,,,) = _rebalance();
        _completeRebalance();

        // 5. Verify rewards were harvested
        assertEq(rewardsDelta, expectedRewards, "rewardsDelta should equal accrued rewards");

        // 6. RewardsAccumulator should be drained
        assertEq(rewardsAccumulator.balance(), 0, "RewardsAccumulator should be drained to 0");

        // 7. Vault buffer increased by reward amount (minus fees deducted as shares)
        uint256 vaultBufferAfter = vault.bufferedAssets();
        assertEq(vaultBufferAfter, vaultBufferBefore + expectedRewards, "Vault buffer should increase by rewards");

        // 8. Fee shares minted to treasury and provider
        uint256 treasurySharesAfter = stAztec.balanceOf(treasury);
        uint256 providerSharesAfter = stAztec.balanceOf(providerRewards);
        assertGt(treasurySharesAfter, treasurySharesBefore, "Treasury should have received fee shares");
        assertGt(providerSharesAfter, providerSharesBefore, "Provider should have received fee shares");

        // 9. Treasury + provider shares = total protocol fee shares
        uint256 totalFeeShares =
            (treasurySharesAfter - treasurySharesBefore) + (providerSharesAfter - providerSharesBefore);
        assertGt(totalFeeShares, 0, "Total fee shares should be positive");

        // 10. Accounting state reflects updated rewards
        IOllaCore.AccountingState memory stateAfterHarvest = core.accountingState();
        assertGt(stateAfterHarvest.cumulativeRewards, 0, "cumulativeRewards should reflect harvest");

        // 11. Exchange rate should have increased (rewards added value)
        uint256 rateAfter = core.exchangeRate();
        assertGt(rateAfter, 1e18, "Exchange rate should be > 1 after rewards");
    }

    /// @notice Zero rewards: no tick, no fees, no buffer change from rewards
    function test_RewardHarvest_ZeroRewards() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 2;

        // Deposit and stake
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // Do NOT accrue any rewards (no tick)
        _warpPastCooldown();

        uint256 treasurySharesBefore = stAztec.balanceOf(treasury);
        uint256 providerSharesBefore = stAztec.balanceOf(providerRewards);
        uint256 bufferBefore = vault.bufferedAssets();

        (uint256 rewardsDelta,,,) = _rebalance();
        _completeRebalance();

        // No rewards harvested
        assertEq(rewardsDelta, 0, "rewardsDelta should be 0 when no rewards accrued");

        // No fee shares minted
        assertEq(stAztec.balanceOf(treasury), treasurySharesBefore, "No treasury shares on zero rewards");
        assertEq(stAztec.balanceOf(providerRewards), providerSharesBefore, "No provider shares on zero rewards");

        // RewardsAccumulator unchanged
        assertEq(rewardsAccumulator.balance(), 0, "RewardsAccumulator balance should remain 0");

        // Buffer unchanged from rewards (may change from staking flows)
        assertEq(vault.bufferedAssets(), bufferBefore, "Buffer unchanged on zero rewards");
    }

    /// @notice Multiple harvest cycles produce cumulative fee results and monotonic exchange rate
    function test_RewardHarvest_MultipleHarvestCycles() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 3;

        // Deposit and stake
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        uint256 rateBefore = core.exchangeRate();

        // --- Harvest 1: 50 seconds of rewards ---
        vm.warp(block.timestamp + 50);
        mockRollup.tick(address(rewardsAccumulator));
        _warpPastCooldown();

        uint256 treasuryShares1Before = stAztec.balanceOf(treasury);
        uint256 providerShares1Before = stAztec.balanceOf(providerRewards);

        (uint256 rewards1,,,) = _rebalance();
        _completeRebalance();
        assertGt(rewards1, 0, "Harvest 1 should yield rewards");

        uint256 rateAfter1 = core.exchangeRate();
        assertGt(rateAfter1, rateBefore, "Rate should increase after harvest 1");

        uint256 treasuryShares1 = stAztec.balanceOf(treasury) - treasuryShares1Before;
        uint256 providerShares1 = stAztec.balanceOf(providerRewards) - providerShares1Before;

        // --- Harvest 2: 75 seconds of rewards ---
        vm.warp(block.timestamp + 75);
        mockRollup.tick(address(rewardsAccumulator));
        _warpPastCooldown();

        uint256 treasuryShares2Before = stAztec.balanceOf(treasury);
        uint256 providerShares2Before = stAztec.balanceOf(providerRewards);

        (uint256 rewards2,,,) = _rebalance();
        _completeRebalance();
        assertGt(rewards2, 0, "Harvest 2 should yield rewards");

        uint256 rateAfter2 = core.exchangeRate();
        assertGt(rateAfter2, rateAfter1, "Rate should increase monotonically after harvest 2");

        uint256 treasuryShares2 = stAztec.balanceOf(treasury) - treasuryShares2Before;
        uint256 providerShares2 = stAztec.balanceOf(providerRewards) - providerShares2Before;

        // Cumulative fee shares = sum of both harvests
        uint256 totalTreasuryShares = treasuryShares1 + treasuryShares2;
        uint256 totalProviderShares = providerShares1 + providerShares2;
        assertEq(stAztec.balanceOf(treasury), treasuryShares1Before + totalTreasuryShares, "Cumulative treasury shares");
        assertEq(
            stAztec.balanceOf(providerRewards),
            providerShares1Before + totalProviderShares,
            "Cumulative provider shares"
        );
    }

    /// @notice Verify fee distribution with specific protocol fee and treasury split percentages
    function test_RewardHarvest_FeeDistribution_TreasurySplit() external {
        // Set protocolFeeBP = 1000 (10%), treasuryFeeSplitBP = 5000 (50/50)
        _scheduleAndExecute(
            address(gov), abi.encodeCall(gov.setProtocolFeeBP, (1_000)), keccak256("setProtocolFeeBP-1000")
        );

        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 3;

        // Deposit and stake
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // Accrue exactly 100 AZTEC in rewards (100 seconds at 1 AZTEC/s)
        vm.warp(block.timestamp + 100);
        mockRollup.tick(address(rewardsAccumulator));
        _warpPastCooldown();

        // Record events for fee verification
        vm.recordLogs();
        _rebalance();
        _completeRebalance();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Find OllaProtocolFeesPaid event
        bytes32 feesTopic = OllaProtocolFeesPaid.selector;
        uint256 feeAssets;
        uint256 emittedTreasuryShares;
        uint256 emittedProviderShares;
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(core) && entries[i].topics[0] == feesTopic) {
                (feeAssets, emittedTreasuryShares, emittedProviderShares) =
                    abi.decode(entries[i].data, (uint256, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "OllaProtocolFeesPaid event should be emitted");

        // Protocol fee = 10% of 100 AZTEC = 10 AZTEC
        uint256 expectedFeeAssets = 100 * DECIMALS * 1_000 / BP_DIVISOR;
        assertEq(feeAssets, expectedFeeAssets, "Protocol fee assets should be 10% of rewards");

        // Treasury/provider split should be ~50/50
        uint256 totalShares = emittedTreasuryShares + emittedProviderShares;
        assertGt(totalShares, 0, "Total fee shares should be positive");

        // Treasury should get ~50% (within rounding)
        uint256 expectedTreasuryShares = totalShares * TREASURY_FEE_SPLIT_BP / BP_DIVISOR;
        assertApproxEqAbs(emittedTreasuryShares, expectedTreasuryShares, 1, "Treasury ~50% of fee shares");
    }

    /// @notice Verify that the claim revert path on MockAztecRollup is handled gracefully
    function test_RewardHarvest_ClaimSequencerRewards_Reverts() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 2;

        // Deposit and stake
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // Accrue rewards (50 seconds at 1 AZTEC/s)
        vm.warp(block.timestamp + 50);
        mockRollup.tick(address(rewardsAccumulator));

        // Make claim fail
        mockRollup.setClaimShouldFail(address(rewardsAccumulator), true);

        _warpPastCooldown();

        // Rebalance should succeed despite claimSequencerRewards reverting
        vm.recordLogs();
        (uint256 rewardsDelta,,,) = _rebalance();
        _completeRebalance();

        // Verify RewardsHarvestFailed event was emitted by StakingManager
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 harvestFailedTopic = RewardsHarvestFailed.selector;
        bool foundHarvestFailed;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(stakingManager) && entries[i].topics[0] == harvestFailedTopic) {
                foundHarvestFailed = true;
            }
        }
        assertTrue(foundHarvestFailed, "RewardsHarvestFailed event should be emitted");

        // No rewards harvested when claim fails
        assertEq(rewardsDelta, 0, "rewardsDelta should be 0 when claim fails");

        // Clear the failure flag and verify system recovers
        mockRollup.setClaimShouldFail(address(rewardsAccumulator), false);

        _warpPastCooldown();
        (uint256 rewardsDeltaAfterRecovery,,,) = _rebalance();
        _completeRebalance();

        assertGt(rewardsDeltaAfterRecovery, 0, "Should harvest rewards after recovery");
    }

    /// @notice Verify RewardsAccumulator recordBalance delta tracking with external donation
    function test_RewardHarvest_RewardsAccumulator_RecordBalance() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 2;

        // Deposit and stake
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // Simulate an unexpected donation directly to RewardsAccumulator
        uint256 donationAmount = 50 * DECIMALS;
        asset.mint(address(rewardsAccumulator), donationAmount);

        // Accrue normal rewards too (30 seconds at 1 AZTEC/s)
        vm.warp(block.timestamp + 30);
        mockRollup.tick(address(rewardsAccumulator));
        uint256 normalRewards = 30 * DECIMALS;

        _warpPastCooldown();

        // Rebalance triggers harvest + recordBalance
        (uint256 rewardsDelta,,,) = _rebalance();
        _completeRebalance();

        // rewardsDelta should include both the donation and normal rewards
        assertEq(rewardsDelta, normalRewards + donationAmount, "Delta should include donation + normal rewards");

        // RewardsAccumulator should be fully drained
        assertEq(rewardsAccumulator.balance(), 0, "RewardsAccumulator should be drained");
    }

    /// @notice Depositors who enter before rewards should benefit; those who enter after should not
    function test_RewardHarvest_DepositorsShareRewards() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 2;

        // User A deposits before rewards
        uint256 sharesA = _deposit(alice, depositAmount);

        // Stake
        _rebalance();
        _completeRebalance();

        // Accrue rewards (100 seconds at 1 AZTEC/s)
        vm.warp(block.timestamp + 100);
        mockRollup.tick(address(rewardsAccumulator));

        // Harvest rewards
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // Exchange rate has increased
        uint256 rateAfterRewards = core.exchangeRate();
        assertGt(rateAfterRewards, 1e18, "Rate should be > 1 after rewards");

        // User B deposits the same amount after rewards
        uint256 sharesB = _deposit(bob, depositAmount);

        // User A got more shares per asset (deposited when rate was 1:1)
        // User B gets fewer shares per asset (depositing when rate > 1:1)
        assertGt(sharesA, sharesB, "User A should have more shares than User B for same deposit");

        // User A's shares are worth more assets now
        uint256 assetsA = core.convertToAssets(sharesA);
        uint256 assetsB = core.convertToAssets(sharesB);

        // User A captured the rewards, so their shares are worth more than their original deposit
        assertGt(assetsA, depositAmount, "User A's shares should be worth more than their deposit");

        // User B just deposited at the current rate, so their shares are worth ~their deposit
        assertApproxEqRel(assetsB, depositAmount, 0.01e18, "User B's shares worth ~deposit");
    }

    /// @notice Verify the forceApprove(0) cleanup on StakingManager after staking (line 357)
    function test_RewardHarvest_StakingManager_ForceApproveCleanup() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 3;

        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // After staking, the StakingManager should have zero allowance to the rollup
        uint256 allowance = asset.allowance(address(stakingManager), address(mockRollup));
        assertEq(allowance, 0, "StakingManager should clear rollup approval after staking");
    }
}
