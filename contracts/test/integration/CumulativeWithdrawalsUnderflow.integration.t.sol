// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { OllaVault } from "src/vault/OllaVault.sol";

/// @title OllaCoreHarnessForCumulativeTest
/// @notice Harness that exposes _applyAccountingUpdates for direct slashing injection.
contract OllaCoreHarnessForCumulativeTest is OllaCore {
    function exposedApplyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsAccumulatorBalance,
        uint256 newClaimableRewards,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) external {
        _applyAccountingUpdates(
            newStakedPrincipal, newRewardsAccumulatorBalance, newClaimableRewards, newRewardsDelta, newSlashingDelta
        );
    }
}

/// @title CumulativeWithdrawalsUnderflowTest
/// @notice Tests that `cumulativeWithdrawals -= totalAdjusted` in OllaVault.finalizeWithdrawals
///         does not underflow under normal slashing, severe slashing, or multiple finalization rounds.
/// @dev Uses exposedApplyAccountingUpdates to inject stakedPrincipal into the accounting state so
///      that slashingDelta properly reduces the exchange rate used for withdrawal finalization.
///      The MockStakingManager cachedState must be kept in sync with the accounting state to pass
///      the monotonicity check on slashingDelta during rebalance.
contract CumulativeWithdrawalsUnderflowTest is Test {
    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarnessForCumulativeTest internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    WithdrawalQueue internal queue;
    address internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarnessForCumulativeTest coreImplementation = new OllaCoreHarnessForCumulativeTest();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarnessForCumulativeTest(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        queue = WithdrawalQueue(address(queueProxy));

        queue.initialize(address(vault), governance, 180_000);

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(queue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    function _requestRedeem(address owner, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, owner, owner);
        return requestId;
    }

    function _warpPastCooldown() internal {
        vm.warp(block.timestamp + 1 hours + 1);
    }

    /// @notice Injects slashing into both the core accounting state and the MockStakingManager,
    ///         keeping them in sync so the monotonicity check passes during rebalance.
    function _injectSlashing(uint256 stakedPrincipal, uint256 slashingDelta) internal {
        // Update core's internal accounting state
        core.exposedApplyAccountingUpdates(stakedPrincipal, 0, 0, 0, slashingDelta);
        // Keep MockStakingManager in sync: stakedAmount matches stakedPrincipal,
        // slashingDelta matches the cumulative slashing
        stakingManager.mockSetCachedState(slashingDelta, stakedPrincipal, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Normal slashing: cumulativeWithdrawals does not underflow after adjustment.
    /// @dev Deposits 100 ether, injects 50 ether as stakedPrincipal to set a meaningful exchange
    ///      rate, then introduces 20 ether slashingDelta to reduce the rate before finalization.
    function test_CumulativeWithdrawals_NoUnderflow_NormalSlashing() external {
        uint256 depositAmount = 100 ether;
        uint256 shares = _deposit(alice, depositAmount);

        // Set stakedPrincipal to 50 ether so totalAssets = 100 (buffered) + 50 (staked) = 150
        // Exchange rate will be > 1:1, giving users more assets per share
        _injectSlashing(50 ether, 0);

        // Request partial redeem at the elevated rate
        uint256 redeemShares = shares / 2;
        uint256 requestId = _requestRedeem(alice, redeemShares);

        IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(requestId);
        uint256 assetsExpected = req.assetsExpected;

        uint256 cumulativeBefore = vault.cumulativeWithdrawals();
        assertEq(cumulativeBefore, assetsExpected, "cumulativeWithdrawals should equal assetsExpected");

        // Inject slashing: reduce stakedPrincipal from 50 to 30 (20 ether slashed)
        // New totalAssets = 100 (buffered) + 30 (staked) = 130, down from 150
        // This drops the exchange rate, triggering slashing adjustment on finalization
        _injectSlashing(30 ether, 20 ether);

        // Rebalance triggers finalization with the slashed rate
        core.rebalance();

        // cumulativeWithdrawals should still be valid (no underflow)
        uint256 cumulativeAfter = vault.cumulativeWithdrawals();
        assertLe(
            cumulativeAfter, cumulativeBefore, "cumulativeWithdrawals should decrease or stay same after adjustment"
        );
    }

    /// @notice Severe slashing (90% loss): cumulativeWithdrawals does not underflow.
    /// @dev Deposits 200 ether (both users), injects stakedPrincipal, then slashes 90%.
    ///      Uses a partial redeem so the adjusted payout fits within the buffered assets.
    function test_CumulativeWithdrawals_NoUnderflow_SevereSlashing() external {
        // Both alice and bob deposit to create sufficient buffered assets
        uint256 depositAmount = 100 ether;
        uint256 sharesAlice = _deposit(alice, depositAmount);
        _deposit(bob, depositAmount);

        // Set stakedPrincipal to 100 ether so totalAssets = 200 (buffered) + 100 (staked) = 300
        _injectSlashing(100 ether, 0);

        // Request partial redeem at the elevated rate (~1.5:1)
        uint256 requestId = _requestRedeem(alice, sharesAlice / 2);

        IWithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(requestId);
        uint256 assetsExpected = req.assetsExpected;
        assertGt(assetsExpected, 0, "assetsExpected should be positive");

        uint256 cumulativeBefore = vault.cumulativeWithdrawals();
        assertEq(cumulativeBefore, assetsExpected, "cumulativeWithdrawals should track request");

        // Severe slashing: stakedPrincipal drops from 100 to 10 (90 ether slashed)
        // New totalAssets = 200 (buffered) + 10 (staked) = 210, down from 300
        // The withdrawal rate drops significantly, so the adjustment will be large
        _injectSlashing(10 ether, 90 ether);

        // Rebalance should finalize with heavily reduced payout
        core.rebalance();

        // No underflow -- the key invariant
        // The fact that rebalance completed without revert proves cumulativeWithdrawals -= totalAdjusted
        // did not underflow (Solidity 0.8+ would revert on underflow)
        uint256 cumulativeAfter = vault.cumulativeWithdrawals();
        assertLe(cumulativeAfter, cumulativeBefore, "cumulativeWithdrawals should not increase");

        // The request should be finalized with adjusted amount
        IWithdrawalQueue.WithdrawalRequest memory reqAfter = queue.getRequest(requestId);
        assertTrue(reqAfter.finalized, "request should be finalized even after severe slashing");
        assertLt(reqAfter.assetsExpected, assetsExpected, "payout should be reduced due to severe slashing");
    }

    /// @notice Multiple finalization rounds: cumulativeWithdrawals invariant holds across cycles.
    function test_CumulativeWithdrawals_NoUnderflow_MultipleFinalizationRounds() external {
        uint256 depositAmount = 100 ether;
        uint256 shares = _deposit(alice, depositAmount);

        // Set stakedPrincipal to elevate the exchange rate
        _injectSlashing(50 ether, 0);

        // First batch: request partial redeem
        uint256 firstShares = shares / 4;
        _requestRedeem(alice, firstShares);

        // Finalize first batch (no slashing)
        core.rebalance();

        uint256 cumulativeAfterFirst = vault.cumulativeWithdrawals();
        assertGt(cumulativeAfterFirst, 0, "cumulativeWithdrawals should be positive after first request");

        // Second batch: request another partial redeem
        _warpPastCooldown();
        uint256 secondShares = shares / 4;
        _requestRedeem(alice, secondShares);

        // Apply slashing before finalizing second batch
        // Reduce stakedPrincipal from 50 to 40 (10 ether slashed)
        _injectSlashing(40 ether, 10 ether);

        // Finalize second batch with slashing adjustment
        _warpPastCooldown();
        core.rebalance();

        uint256 cumulativeAfterSecond = vault.cumulativeWithdrawals();
        // The fact that we got here without revert proves no underflow occurred
        assertGt(cumulativeAfterSecond, 0, "cumulativeWithdrawals should remain positive");

        // Third batch: request more shares
        _warpPastCooldown();
        uint256 thirdShares = shares / 4;
        _requestRedeem(alice, thirdShares);

        // Apply more slashing: reduce stakedPrincipal from 40 to 15 (25 ether cumulative slash)
        _injectSlashing(15 ether, 25 ether);

        _warpPastCooldown();
        core.rebalance();

        // The fact that rebalance completed without revert confirms no underflow
        uint256 cumulativeAfterThird = vault.cumulativeWithdrawals();
        assertGt(cumulativeAfterThird, 0, "cumulativeWithdrawals should remain positive after multiple rounds");
    }

    /// @notice Invariant: after any slashing adjustment, cumulativeWithdrawals is correct.
    /// @dev Multi-user scenario with deposits, withdrawals, and slashing.
    function test_CumulativeWithdrawals_InvariantHoldsAfterAdjustment() external {
        uint256 depositAmount = 200 ether;
        uint256 sharesAlice = _deposit(alice, depositAmount);
        _deposit(bob, depositAmount);

        // Set stakedPrincipal to create meaningful exchange rate
        _injectSlashing(100 ether, 0);

        // Alice requests full redeem
        uint256 requestIdAlice = _requestRedeem(alice, sharesAlice);

        IWithdrawalQueue.WithdrawalRequest memory reqAlice = queue.getRequest(requestIdAlice);
        uint256 assetsExpectedAlice = reqAlice.assetsExpected;

        uint256 cumulativeBefore = vault.cumulativeWithdrawals();
        assertEq(cumulativeBefore, assetsExpectedAlice, "cumulative should track alice's request");

        // Apply moderate slashing: reduce stakedPrincipal from 100 to 60 (40 ether slashed)
        _injectSlashing(60 ether, 40 ether);

        // Finalize alice's withdrawal with slashing
        core.rebalance();

        uint256 cumulativeAfterAlice = vault.cumulativeWithdrawals();

        // Key invariant: cumulativeWithdrawals = original - totalAdjusted
        // It should be <= cumulativeBefore
        assertLe(cumulativeAfterAlice, cumulativeBefore, "cumulative should decrease or stay same");

        // Bob requests partial redeem
        _warpPastCooldown();
        uint256 bobShares = stAztec.balanceOf(bob);
        assertGt(bobShares, 0, "Bob should have shares");
        uint256 bobRedeemShares = bobShares / 2;
        _requestRedeem(bob, bobRedeemShares);

        uint256 cumulativeAfterBob = vault.cumulativeWithdrawals();
        assertGt(cumulativeAfterBob, cumulativeAfterAlice, "cumulative should increase after Bob's request");

        // Finalize Bob's withdrawal (no additional slashing -- slashing delta stays at 40)
        _warpPastCooldown();
        core.rebalance();

        // The fact that rebalance completed without revert confirms the invariant held
        uint256 cumulativeFinal = vault.cumulativeWithdrawals();
        assertGt(cumulativeFinal, 0, "cumulativeWithdrawals should be positive in the end");
    }
}
