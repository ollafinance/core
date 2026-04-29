// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { E2EBaseWithRealStaking } from "./E2EBaseWithRealStaking.sol";

/// @title InvalidKeyRefundAccountingE2E
/// @notice Regression tests for failed queued-key refunds being swept without double-counting.
contract InvalidKeyRefundAccountingE2E is E2EBaseWithRealStaking {
    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        _deployFullStack();
    }

    /*//////////////////////////////////////////////////////////////
                        FAILED KEY REFUND ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice A failed queued-key refund must not be swept while still counted as staked principal.
    function test_Rebalance_FailedQueuedRefund_DoesNotDoubleCountTotalAssets() external {
        uint256 threshold = mockRollup.getActivationThreshold();

        _setupFailedQueuedKeyRefund(threshold);
        address attester = address(uint160(1));

        assertEq(vault.bufferedAssets(), 0, "pre: stake consumed full buffer");
        assertEq(core.totalAssets(), threshold, "pre: principal counted once as staked");

        _warpPastCooldown();
        _rebalance();

        assertEq(vault.bufferedAssets(), 0, "unpurged refund should not be swept into buffer");
        assertEq(core.totalAssets(), threshold, "unpurged refund must remain counted once");

        stakingManager.purgeFailedQueueEntry(attester);

        _warpPastCooldown();
        _rebalance();

        assertEq(vault.bufferedAssets(), threshold, "purged refund should be swept into buffer");
        assertEq(core.totalAssets(), threshold, "purged refund must not be counted in buffer and principal");
    }

    /// @notice Sweeping a failed queued-key refund must not inflate the user-facing share exchange rate.
    function test_Rebalance_FailedQueuedRefund_DoesNotInflateExchangeRate() external {
        uint256 threshold = mockRollup.getActivationThreshold();

        uint256 shares = _setupFailedQueuedKeyRefund(threshold);
        uint256 rateBefore = core.exchangeRate();
        uint256 assetsBefore = core.convertToAssets(shares);

        _warpPastCooldown();
        _rebalance();

        assertEq(core.exchangeRate(), rateBefore, "refund reclassification should preserve exchange rate");
        assertEq(core.convertToAssets(shares), assetsBefore, "refund should not increase redeemable assets");

        stakingManager.purgeFailedQueueEntry(address(uint160(1)));

        _warpPastCooldown();
        _rebalance();

        assertEq(core.exchangeRate(), rateBefore, "purged refund should preserve exchange rate");
        assertEq(core.convertToAssets(shares), assetsBefore, "purged refund should not increase redeemable assets");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Creates a single staked queued entry, then simulates the rollup refunding it after flush failure.
    function _setupFailedQueuedKeyRefund(uint256 threshold) internal returns (uint256 shares) {
        _addKeys(1);
        shares = _deposit(alice, threshold);

        _rebalance();

        address attester = address(uint160(1));

        // Simulate an invalid PoP / failed GSE deposit after the rollup entry queue is flushed:
        // the attester is no longer validating on the rollup, and the stake is refunded to Olla's
        // StakingManager without any callback that updates its aggregate stakedAmount.
        mockRollup.clearAttester(attester);
        asset.mint(address(stakingManager), threshold);

        IStakingManager.StakingState memory stakingState = stakingManager.getStakingState();
        assertEq(stakingState.stakedAmount, threshold, "pre: failed queued stake still cached as staked");
        assertEq(asset.balanceOf(address(stakingManager)), threshold, "pre: refund sits in staking manager");

        IOllaCore.AccountingState memory accountingState = core.accountingState();
        assertEq(accountingState.stakedPrincipal, threshold, "pre: core reads cached staking principal");
    }
}
