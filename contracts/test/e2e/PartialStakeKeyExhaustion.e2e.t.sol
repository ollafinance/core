// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { E2EBaseWithRealStaking } from "./E2EBaseWithRealStaking.sol";

/// @title PartialStakeKeyExhaustionE2E
/// @notice E2E: validates behavior when StakingManager cannot stake all requested funds due to
///         key queue exhaustion or partial fills. Exercises OllaCore's excess-return-to-vault path
///         (lines 768-771, catch block) using real StakingManager + real RewardsAccumulator.
contract PartialStakeKeyExhaustionE2E is E2EBaseWithRealStaking {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        _deployFullStack();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the activation threshold (stake per attester).
    function _threshold() internal view returns (uint256) {
        return mockRollup.getActivationThreshold();
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit enough for 3 attesters but only 2 keys available -> 2 staked, excess returned.
    function test_PartialStake_InsufficientKeys() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Add only 2 attester keys
        _addKeys(2);

        // 2. Deposit enough for 3 attesters
        _deposit(alice, depositAmount);
        assertEq(vault.bufferedAssets(), depositAmount, "Initial buffer = deposit");

        // 3. Rebalance -> should stake 2 attesters, return excess for 1
        _rebalance();
        _completeRebalance();

        // 4. Only 2 * threshold staked
        IOllaCore.AccountingState memory state = core.accountingState();
        assertEq(state.stakedPrincipal, threshold * 2, "Only 2 attesters should be staked");

        // 5. Excess returned to vault buffer
        assertEq(vault.bufferedAssets(), threshold, "Excess should be in vault buffer");

        // 6. Key queue should be empty
        assertEq(stakingProviderRegistry.getQueueLength(), 0, "Key queue should be empty");
    }

    /// @notice Zero keys available -> StakingManager reverts, OllaCore catch returns all to vault.
    function test_PartialStake_ZeroKeys() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Add NO keys
        // 2. Deposit
        _deposit(alice, depositAmount);

        // 3. Rebalance -> StakingManager reverts with InsufficientKeys, caught by OllaCore
        _rebalance();
        _completeRebalance();

        // 4. Nothing staked
        IOllaCore.AccountingState memory state = core.accountingState();
        assertEq(state.stakedPrincipal, 0, "stakedPrincipal should be 0 with no keys");

        // 5. All assets remain in vault buffer
        assertEq(vault.bufferedAssets(), depositAmount, "All assets should remain in vault buffer");

        // 6. System continues to function: deposits still work
        uint256 newShares = _deposit(bob, threshold);
        assertGt(newShares, 0, "Deposits should still work after zero-key rebalance");

        // 7. Redeems still work
        uint256 requestId = _requestRedeem(bob, newShares);
        assertGt(requestId, 0, "Redemption requests should still work");
    }

    /// @notice Add keys between rebalances: 1 key -> rebalance (partial) -> add 2 more -> rebalance -> all staked.
    function test_PartialStake_KeysAddedBetweenRebalances() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Add 1 key, deposit enough for 3
        _addKeys(1);
        _deposit(alice, depositAmount);

        // 2. Rebalance 1 -> stakes 1 attester, 2*threshold excess returned to vault
        _rebalance();
        _completeRebalance();

        IOllaCore.AccountingState memory stateAfter1 = core.accountingState();
        assertEq(stateAfter1.stakedPrincipal, threshold, "First rebalance: 1 attester staked");
        assertEq(vault.bufferedAssets(), threshold * 2, "First rebalance: 2*threshold excess in buffer");

        // 3. Add 2 more keys (no new deposit -- canStake detects stakeable surplus)
        _addKeys(2);
        assertEq(stakingProviderRegistry.getQueueLength(), 2, "Queue should have 2 new keys");

        // 4. Rebalance 2 -> stakes 2 more using new keys and buffered surplus
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 5. Total staked = 3 * threshold
        IOllaCore.AccountingState memory stateAfter2 = core.accountingState();
        assertEq(stateAfter2.stakedPrincipal, threshold * 3, "All 3 attesters should be staked");

        // 6. Vault buffer = 0 (all staked)
        assertEq(vault.bufferedAssets(), 0, "Vault buffer should be 0 after full stake");

        // 7. Key queue empty
        assertEq(stakingProviderRegistry.getQueueLength(), 0, "Queue should be empty after using all keys");
    }

    /// @notice Excess return to vault buffer can be used to finalize pending withdrawals.
    function test_PartialStake_ExcessReturnDoesNotAffectPendingWithdrawals() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Add 2 keys, deposit enough for 3
        _addKeys(2);
        _deposit(alice, depositAmount);

        // 2. Request redeem of threshold worth of shares (approximately 1 attester)
        uint256 totalShares = stAztec.balanceOf(alice);
        uint256 redeemShares = totalShares / 3; // ~1 attester worth
        uint256 requestId = _requestRedeem(alice, redeemShares);

        // 3. Rebalance -> stakes 2 keys, returns threshold excess to vault,
        //    and uses buffer to finalize withdrawal
        _rebalance();
        _completeRebalance();

        // May need extra rebalance cycles for full finalization
        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 4. Check withdrawal was finalized
        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertTrue(req.finalized, "Withdrawal should be finalized using excess buffer");

        // 5. User can claim
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);
        assertGt(claimed, 0, "User should claim non-zero amount");

        // 6. Accounting is consistent
        IOllaCore.AccountingState memory state = core.accountingState();
        assertEq(state.stakedPrincipal, threshold * 2, "2 attesters should be staked");
    }

    /// @notice Rewards accrued + no keys left for surplus -> rewards harvested, surplus stays in buffer.
    function test_PartialStake_WithRewardsAndPartialFill() external {
        uint256 threshold = _threshold();

        // 1. Add 2 keys, stake them
        _addKeys(2);
        _deposit(alice, threshold * 2);
        _rebalance();
        _completeRebalance();

        assertEq(core.accountingState().stakedPrincipal, threshold * 2, "2 attesters staked");
        assertEq(stakingProviderRegistry.getQueueLength(), 0, "No keys left");

        // 2. Accrue rewards on rollup
        mockRollup.setRewardRatePerSecond(1 * DECIMALS);
        vm.warp(block.timestamp + 100);
        mockRollup.tick(address(rewardsAccumulator));
        uint256 expectedRewards = 100 * DECIMALS;

        // 3. Deposit more (no keys to stake it)
        _deposit(alice, threshold);

        // 4. Rebalance -> harvests rewards + tries to stake surplus (no keys)
        _warpPastCooldown();

        uint256 treasurySharesBefore = stAztec.balanceOf(treasury);
        uint256 providerSharesBefore = stAztec.balanceOf(providerRewards);

        (uint256 rewardsDelta,,,) = _rebalance();
        _completeRebalance();

        // 5. Rewards harvested correctly
        assertEq(rewardsDelta, expectedRewards, "Rewards should be harvested");

        // 6. Fee shares minted for rewards
        assertGt(stAztec.balanceOf(treasury), treasurySharesBefore, "Treasury should receive fee shares");
        assertGt(stAztec.balanceOf(providerRewards), providerSharesBefore, "Provider should receive fee shares");

        // 7. Surplus stays in vault buffer (no keys to stake)
        // The threshold deposit + rewards should be in the buffer
        assertGt(vault.bufferedAssets(), 0, "Buffer should hold unstakeable surplus");

        // 8. stakedPrincipal unchanged (still 2)
        assertEq(core.accountingState().stakedPrincipal, threshold * 2, "stakedPrincipal unchanged (no new keys)");
    }

    /// @notice dripQueue removes keys, limiting staking; refilling keys allows subsequent staking.
    function test_PartialStake_QueueDripAndRefill() external {
        uint256 threshold = _threshold();

        // 1. Add 5 keys
        _addKeys(5);
        assertEq(stakingProviderRegistry.getQueueLength(), 5, "Queue should have 5 keys");

        // 2. Drip 3 keys (removes them from queue)
        vm.prank(address(gov));
        stakingProviderRegistry.dripQueue(3);
        assertEq(stakingProviderRegistry.getQueueLength(), 2, "Queue should have 2 keys after drip");

        // 3. Deposit enough for 5 attesters
        uint256 depositAmount = threshold * 5;
        _deposit(alice, depositAmount);

        // 4. Rebalance -> stakes only 2 (remaining keys), 3*threshold excess in buffer
        _rebalance();
        _completeRebalance();

        assertEq(core.accountingState().stakedPrincipal, threshold * 2, "Only 2 attesters staked");
        assertEq(vault.bufferedAssets(), threshold * 3, "3*threshold excess in buffer");
        assertEq(stakingProviderRegistry.getQueueLength(), 0, "Queue empty after staking");

        // 5. Add 3 more keys (canStake detects stakeable surplus)
        _addKeys(3);
        assertEq(stakingProviderRegistry.getQueueLength(), 3, "Queue should have 3 new keys");

        // 6. Rebalance -> stakes 3 more from buffered surplus
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 7. All funds now staked
        assertEq(core.accountingState().stakedPrincipal, threshold * 5, "All 5 attesters should be staked");
        assertEq(vault.bufferedAssets(), 0, "Vault buffer should be 0");
    }

    /// @notice Adding keys with surplus in buffer bypasses the idle guard via canStake(),
    ///         so rebalance proceeds without needing forceRebalanceReset.
    function test_PartialStake_NewKeysBreakIdleGuard() external {
        uint256 threshold = _threshold();

        // 1. Add 1 key, deposit enough for 3 attesters
        _addKeys(1);
        _deposit(alice, threshold * 3);

        // 2. Rebalance -> stakes 1 attester, 2*threshold excess in buffer
        _rebalance();
        _completeRebalance();

        assertEq(core.accountingState().stakedPrincipal, threshold, "1 attester staked");
        assertEq(vault.bufferedAssets(), threshold * 2, "2*threshold surplus in buffer");

        // 3. Add 2 more keys -- canStake(surplus) detects stakeable work
        _addKeys(2);

        // 4. Rebalance proceeds despite buffer being unchanged
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        assertEq(core.accountingState().stakedPrincipal, threshold * 3, "All 3 attesters staked");
        assertEq(vault.bufferedAssets(), 0, "Buffer drained after staking");
        assertEq(stakingProviderRegistry.getQueueLength(), 0, "All keys consumed");
    }

    /// @notice Sub-threshold deposit amount -> StakingManager returns 0 staked, all returns to vault.
    function test_PartialStake_StakeAmount_LessThanActivationThreshold() external {
        uint256 threshold = _threshold();

        // 1. Add keys (enough to not be the bottleneck)
        _addKeys(3);

        // 2. Deposit less than one attester stake
        uint256 depositAmount = threshold / 2;
        _deposit(alice, depositAmount);

        // 3. Rebalance -> can't fill even one attester
        _rebalance();
        _completeRebalance();

        // 4. Nothing staked
        assertEq(core.accountingState().stakedPrincipal, 0, "No staking should occur");

        // 5. Full amount remains in vault buffer
        assertEq(vault.bufferedAssets(), depositAmount, "Full amount should remain in buffer");

        // 6. Keys still available
        assertEq(stakingProviderRegistry.getQueueLength(), 3, "Keys should not be consumed");
    }
}
