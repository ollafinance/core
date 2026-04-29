// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { E2EBaseWithRealStaking } from "./E2EBaseWithRealStaking.sol";

/// @title FullStackFeeLifecycleE2E
/// @notice E2E: validates fee lifecycle with real StakingManager, RewardsAccumulator, and MockAztecRollup.
///         Covers deposit -> stake -> accrue rewards -> rebalance -> verify fee minting and rate changes.
contract FullStackFeeLifecycleE2E is E2EBaseWithRealStaking {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OllaProtocolFeesPaid(uint256 protocolFeeAssets, uint256 treasuryShares, uint256 providerShares);
    event FeesMinted(uint256 treasuryShares, uint256 providerShares);

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
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Searches recorded logs for OllaProtocolFeesPaid on core.
    function _findFeeEvent(Vm.Log[] memory entries)
        internal
        view
        returns (bool found, uint256 feeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        bytes32 topic = OllaProtocolFeesPaid.selector;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(core) && entries[i].topics[0] == topic) {
                (feeAssets, treasuryShares, providerShares) = abi.decode(entries[i].data, (uint256, uint256, uint256));
                return (true, feeAssets, treasuryShares, providerShares);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
     TEST 1: DEPOSIT -> STAKE -> REWARDS -> HARVEST -> FEE SPLIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Full lifecycle with real staking: deposit, stake, accrue rewards, rebalance,
    ///         verify correct fee minting and treasury/provider split.
    function test_FullLifecycle_DepositStakeRewardsFeeDistribution() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 numAttesters = 3;
        uint256 depositAmount = activationThreshold * numAttesters;

        // 1. Deposit
        _deposit(alice, depositAmount);

        // 2. Rebalance -> stakes attesters
        _rebalance();
        _completeRebalance();

        IOllaCore.AccountingState memory stateAfterStake = core.accountingState();
        assertEq(stateAfterStake.stakedPrincipal, depositAmount, "All deposited assets staked");

        // 3. Accrue 200 seconds of rewards (200 AZTEC at 1/sec)
        uint256 rewardDuration = 200;
        vm.warp(block.timestamp + rewardDuration);
        mockRollup.tick(address(rewardsAccumulator));

        // 4. Rebalance -> harvest rewards and distribute fees
        _warpPastCooldown();

        uint256 treasuryBefore = stAztec.balanceOf(treasury);
        uint256 providerBefore = stAztec.balanceOf(providerRewards);
        uint256 supplyBefore = stAztec.totalSupply();

        vm.recordLogs();
        (uint256 rewardsDelta,,,) = _rebalance();
        _completeRebalance();

        // 5. Verify rewards were harvested
        assertGt(rewardsDelta, 0, "rewardsDelta should be positive");

        // 6. Verify fee minting occurred
        uint256 treasuryAfter = stAztec.balanceOf(treasury);
        uint256 providerAfter = stAztec.balanceOf(providerRewards);
        assertGt(treasuryAfter, treasuryBefore, "Treasury should receive fee shares");
        assertGt(providerAfter, providerBefore, "Provider should receive fee shares");

        // 7. Verify approximate 50/50 split (default TREASURY_FEE_SPLIT_BP = 5_000)
        uint256 treasuryDelta = treasuryAfter - treasuryBefore;
        uint256 providerDelta = providerAfter - providerBefore;
        assertApproxEqAbs(treasuryDelta, providerDelta, 1, "50/50 split: treasury ~= provider");

        // 8. Total supply increased from fee minting
        assertGt(stAztec.totalSupply(), supplyBefore, "Supply should increase from fee minting");

        // 9. Verify fee event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (bool found, uint256 feeAssets, uint256 evtTreasury, uint256 evtProvider) = _findFeeEvent(entries);
        assertTrue(found, "OllaProtocolFeesPaid should be emitted");
        uint256 expectedFeeAssets = rewardsDelta * PROTOCOL_FEE_BP / BP_DIVISOR;
        assertEq(feeAssets, expectedFeeAssets, "Fee assets = 5% of rewards");
        assertEq(evtTreasury, treasuryDelta, "Event treasury shares matches balance");
        assertEq(evtProvider, providerDelta, "Event provider shares matches balance");
    }

    /*//////////////////////////////////////////////////////////////
     TEST 2: EXCHANGE RATE RISES AFTER REWARDS (POST-FEE)
    //////////////////////////////////////////////////////////////*/

    /// @notice After rewards with fees, the exchange rate should rise but less than without fees.
    function test_ExchangeRateRisesAfterRewardsWithFees() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 3;

        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        uint256 rateBefore = core.exchangeRate();

        // Accrue 100 AZTEC rewards
        vm.warp(block.timestamp + 100);
        mockRollup.tick(address(rewardsAccumulator));
        _warpPastCooldown();

        _rebalance();
        _completeRebalance();

        uint256 rateAfter = core.exchangeRate();

        // Rate should increase (rewards added value)
        assertGt(rateAfter, rateBefore, "Exchange rate should increase after rewards");

        // But rate increase should be less than raw rewards/deposit ratio due to fee dilution
        // Without fees: rate increase = rewards / deposit = 100 / (3 * threshold)
        // With 5% fees: some of the rate increase is captured by fee shares
        uint256 totalAssets = core.totalAssets();
        uint256 totalSupply = stAztec.totalSupply();
        uint256 aliceShares = stAztec.balanceOf(alice);

        // Alice should not capture 100% of the reward value - some went to fees
        uint256 aliceValue = aliceShares.mulDiv(totalAssets + 1e3, totalSupply + 1e3, Math.Rounding.Floor);
        assertLt(aliceValue, depositAmount + 100 * DECIMALS, "Alice captures less than gross rewards");
        assertGt(aliceValue, depositAmount + 90 * DECIMALS, "Alice retains most rewards (>90%)");
    }

    /*//////////////////////////////////////////////////////////////
     TEST 3: FEE SPLIT CHANGE VIA GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifying different treasury fee splits produce the expected ratios.
    ///         Cycle 1 uses default 50/50, then governance changes to 80/20, and cycle 2 uses the new split.
    function test_GovernanceFeeParamChange_ReflectedInNextCycle() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 3;

        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // Cycle 1: default 50/50 split
        vm.warp(block.timestamp + 100);
        mockRollup.tick(address(rewardsAccumulator));
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        uint256 treasuryBal1 = stAztec.balanceOf(treasury);
        uint256 providerBal1 = stAztec.balanceOf(providerRewards);
        assertApproxEqAbs(treasuryBal1, providerBal1, 1, "Cycle 1: 50/50 split");

        // Change to 80/20 split via governance.
        // _scheduleAndExecute warps forward by MIN_DELAY for the timelock. After execution
        // lastTick is synced so subsequent tick() only accrues from this point.
        // Capture the pre-governance timestamp so we can compute post-governance time.
        uint256 tsBeforeGov = block.timestamp;
        _scheduleAndExecute(
            address(gov), abi.encodeCall(gov.setTreasuryFeeSplitBP, (8_000)), keccak256("setTreasuryFeeSplitBP-8000")
        );
        assertEq(core.treasuryFeeSplitBP(), 8_000, "Treasury split should be 8000");

        // Cycle 2: should use new 80/20 split.
        // _scheduleAndExecute warped to tsBeforeGov + MIN_DELAY. Accrue 100 seconds of rewards.
        uint256 tsAfterGov = tsBeforeGov + 1 days; // MIN_DELAY = 1 days
        vm.warp(tsAfterGov + 100);
        mockRollup.tick(address(rewardsAccumulator));
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        uint256 treasuryDelta2 = stAztec.balanceOf(treasury) - treasuryBal1;
        uint256 providerDelta2 = stAztec.balanceOf(providerRewards) - providerBal1;

        // 80/20: treasuryDelta2 * 2 ~= providerDelta2 * 8
        assertGt(treasuryDelta2, providerDelta2, "Cycle 2: treasury > provider with 80/20 split");
        assertApproxEqAbs(treasuryDelta2 * 2, providerDelta2 * 8, 10, "Cycle 2: 80/20 split ratio");
    }

    /*//////////////////////////////////////////////////////////////
     TEST 4: SLASHING NEGATES REWARDS -> NO FEES
    //////////////////////////////////////////////////////////////*/

    /// @notice When slashing exceeds rewards, gross rewards are zero and no fees are minted.
    function test_SlashingNegatesRewards_NoFeesMinted() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 numAttesters = 3;
        uint256 depositAmount = activationThreshold * numAttesters;

        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        uint256 supplyBefore = stAztec.totalSupply();
        uint256 rateBefore = core.exchangeRate();

        // Accrue 50 seconds of rewards (50 AZTEC)
        vm.warp(block.timestamp + 50);
        mockRollup.tick(address(rewardsAccumulator));

        // Slash all 3 attesters: reduce each stake by 50% via zombie exits
        address[] memory attesters = _allAttesterAddresses();
        for (uint256 i = 0; i < numAttesters; ++i) {
            // Create zombie exits with reduced amounts (partial slash)
            mockRollup.setExternalExit(attesters[i], activationThreshold / 2, block.timestamp);
        }
        _refreshAttesters();

        _warpPastCooldown();

        // Rebalance should detect slashing > rewards
        _rebalance();
        _completeRebalance();

        // No fee shares should be minted (slashing wiped out rewards and then some)
        assertEq(stAztec.balanceOf(treasury), 0, "Treasury should have 0 (slashing > rewards)");
        assertEq(stAztec.balanceOf(providerRewards), 0, "Provider should have 0");
        assertEq(stAztec.totalSupply(), supplyBefore, "Supply unchanged (no fee minting)");

        // Exchange rate should drop
        assertLt(core.exchangeRate(), rateBefore, "Exchange rate should drop after slashing");
    }

    /*//////////////////////////////////////////////////////////////
     TEST 5: MULTI-CYCLE FEE ACCUMULATION WITH REAL STAKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Multiple reward harvest cycles accumulate fee shares monotonically.
    function test_MultiCycle_FeeAccumulation_MonotonicRateIncrease() external {
        uint256 activationThreshold = mockRollup.getActivationThreshold();
        uint256 depositAmount = activationThreshold * 3;

        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        uint256 ratePrev = core.exchangeRate();
        uint256 cumulativeRewardsPrev = core.accountingState().cumulativeRewards;

        // Run 3 reward cycles with manually tracked timestamps.
        // NOTE: the Solidity optimizer may cache block.timestamp within a function,
        // so we track time explicitly to avoid stale reads after vm.warp.
        uint256 ts = block.timestamp;
        for (uint256 cycle = 1; cycle <= 3; ++cycle) {
            // Accrue 60 seconds of rewards
            ts += 60;
            vm.warp(ts);
            mockRollup.tick(address(rewardsAccumulator));

            // Warp past cooldown (1 hour + 1 second)
            ts += 1 hours + 1;
            vm.warp(ts);
            mockRollup.tick(address(0xdead)); // sync lastTick (same as _warpPastCooldown)

            _rebalance();
            _completeRebalance();

            uint256 rateNow = core.exchangeRate();
            uint256 cumulativeRewardsNow = core.accountingState().cumulativeRewards;

            // Rate must increase monotonically
            assertGt(rateNow, ratePrev, "Rate should increase each cycle");
            // Cumulative rewards must increase
            assertGt(cumulativeRewardsNow, cumulativeRewardsPrev, "Cumulative rewards should increase");

            ratePrev = rateNow;
            cumulativeRewardsPrev = cumulativeRewardsNow;
        }

        // Treasury and provider should have accumulated fee shares
        assertGt(stAztec.balanceOf(treasury), 0, "Treasury should have accumulated shares");
        assertGt(stAztec.balanceOf(providerRewards), 0, "Provider should have accumulated shares");

        // Conservation: sum of share values approximates totalAssets
        uint256 totalAssets = core.totalAssets();
        uint256 totalSupply = stAztec.totalSupply();
        uint256 aliceValue = stAztec.balanceOf(alice).mulDiv(totalAssets + 1e3, totalSupply + 1e3, Math.Rounding.Floor);
        uint256 treasuryValue =
            stAztec.balanceOf(treasury).mulDiv(totalAssets + 1e3, totalSupply + 1e3, Math.Rounding.Floor);
        uint256 providerValue =
            stAztec.balanceOf(providerRewards).mulDiv(totalAssets + 1e3, totalSupply + 1e3, Math.Rounding.Floor);

        assertApproxEqRel(
            aliceValue + treasuryValue + providerValue,
            totalAssets,
            0.001e18, // 0.1% tolerance
            "Conservation: sum of share values ~= totalAssets"
        );
    }
}
