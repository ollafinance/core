// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsCollector } from "src/core/mocks/MockRewardsCollector.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaCoreRebalanceFinalizeDeadlockTest
/// @notice Regression and coverage tests for the rebalance FinalizeWithdrawals deadlock fix.
///
///         The bug: when a pending withdrawal request is larger than the buffered balance,
///         `_finalizeWithdrawals()` returns `finalizedAmount = 0` but `pending > 0 && buffer > 0`
///         caused the state machine to early-return instead of advancing to InitiateUnstake.
///
///         Change 1: FinalizeWithdrawals now also advances when `finalizedAmount == 0`.
///         Change 2: `_rebalanceCompletionSatisfied` allows completion when `pending > 0 && buffer > 0`
///         provided there are no pending unstakes (the protocol has done all it can).
contract OllaCoreRebalanceFinalizeDeadlockTest is Test {
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
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsCollector internal rewardsCollector;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal operator;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        operator = makeAddr("operator");

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation),
            abi.encodeCall(WithdrawalQueue.initialize, (address(vault), governance, 180_000))
        );
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        rewardsCollector = new MockRewardsCollector(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsCollector(address(rewardsCollector));
        stakingManager.setUnstakedToken(asset);

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsCollector, address(safetyModule));

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");

        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.startPrank(governance);
        core.grantRole(operatorRole, operator);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    function _requestRedeem(address owner, uint256 shares, address recipient)
        internal
        returns (uint256 requestId, uint256 assetsExpected)
    {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, recipient, owner);
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        assetsExpected = request.assetsExpected;
        return (requestId, assetsExpected);
    }

    /// @dev Stakes all buffered assets via a full rebalance cycle.
    ///      Sets mock `totalStaked` before the rebalance so the accounting update
    ///      (which reads `totalStaked()` during completion) sees the correct value.
    function _stakeAll(uint256 stakeAmount) internal {
        stakingManager.setStakeReturnAmount(stakeAmount);
        stakingManager.setAllowStakeReturnExceeds(true);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        // Pre-set totalStaked so the accounting update at rebalance completion reads
        // the correct staked principal from the mock.
        stakingManager.setTotalStaked(stakeAmount);

        vm.prank(operator);
        core.rebalance();

        // Complete multi-step if needed
        for (uint256 i; i < 5; ++i) {
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        // Advance past rebalance cooldown so the next cycle can start
        vm.warp(block.timestamp + 1 hours);
    }

    /// @dev Injects buffer by minting tokens directly to the vault and reconciling.
    function _injectBuffer(uint256 amount) internal {
        asset.mint(address(vault), amount);
        vm.prank(governance);
        vault.reconcileBufferedAssets();
    }

    /*//////////////////////////////////////////////////////////////
                     FINALIZE ADVANCES ON ZERO PROGRESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Core regression test for the deadlock bug.
    ///         When `_finalizeWithdrawals()` returns 0 (request larger than buffer),
    ///         the state machine must advance past FinalizeWithdrawals to InitiateUnstake.
    function test_Rebalance_FinalizeAdvancesWhenRequestExceedsBuffer() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        _stakeAll(depositAmount);

        // Inject 3 DECIMALS of "rewards" to create buffer
        _injectBuffer(3 * DECIMALS);

        assertEq(vault.bufferedAssets(), 3 * DECIMALS, "buffer should be 3 DECIMALS");

        // Request withdrawal for 8 DECIMALS worth of shares (more than 3 DECIMALS buffer)
        uint256 sharesToRedeem = core.convertToShares(8 * DECIMALS);
        if (sharesToRedeem > shares) {
            sharesToRedeem = shares;
        }
        (, uint256 assetsExpected) = _requestRedeem(alice, sharesToRedeem, alice);
        assertGt(assetsExpected, 3 * DECIMALS, "request should exceed buffer");

        // Ensure staking manager reports no new rewards or unstaked funds
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);

        // Rebalance: should advance past FinalizeWithdrawals
        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();

        // Should have advanced past FinalizeWithdrawals (step 2)
        assertGt(
            uint256(progress.step),
            uint256(IOllaCore.RebalanceStep.FinalizeWithdrawals),
            "should advance past FinalizeWithdrawals when request exceeds buffer"
        );

        // Should have computed an unstake amount since we need more than the buffer
        // After the unstake step runs, unstakeRemaining may already be 0 (unstake initiated),
        // so check that it was nonzero before being consumed, OR that we passed through InitiateUnstake.
        assertGe(
            uint256(progress.step),
            uint256(IOllaCore.RebalanceStep.InitiateUnstake),
            "should reach at least InitiateUnstake"
        );
    }

    /*//////////////////////////////////////////////////////////////
              FULL CYCLE: LARGE WITHDRAWAL UNSTAKE AND FINALIZE
    //////////////////////////////////////////////////////////////*/

    /// @notice End-to-end test: deposit → stake → request large withdrawal → rebalance through
    ///         all steps until claim succeeds.
    function test_Rebalance_FullCycleLargeWithdrawal_UnstakeAndFinalize() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 depositAmount = 100 * DECIMALS;
        uint256 allShares = _performDeposit(alice, depositAmount);
        _stakeAll(depositAmount);

        // Inject 5 DECIMALS buffer (simulates rewards/leftover)
        _injectBuffer(5 * DECIMALS);

        assertEq(vault.bufferedAssets(), 5 * DECIMALS, "buffer should be 5 DECIMALS");

        // Request withdrawal of all shares. With totalStaked=100 and buffer=5, totalAssets=105.
        // Exchange rate = 105/100 = 1.05, so allShares (100) converts to 105 DECIMALS.
        (uint256 requestId, uint256 assetsExpected) = _requestRedeem(alice, allShares, alice);
        assertGt(assetsExpected, 5 * DECIMALS, "withdrawal should exceed buffer");

        uint256 unstakeNeeded = assetsExpected - 5 * DECIMALS;

        // --- First rebalance cycle ---
        // The mock unstake() returns the requested amount but doesn't update pendingUnstakeAmount.
        // Pre-set pendingUnstakes so completion check sees in-flight unstakes and keeps pause.
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setPendingUnstakes(unstakeNeeded);

        // Run the first rebalance cycle to completion
        for (uint256 i; i < 10; ++i) {
            vm.prank(operator);
            core.rebalance();

            IOllaCore.RebalanceProgress memory pLoop = core.rebalanceProgress();
            if (pLoop.step == IOllaCore.RebalanceStep.Done) break;
        }

        IOllaCore.RebalanceProgress memory p1 = core.rebalanceProgress();
        assertEq(uint256(p1.step), uint256(IOllaCore.RebalanceStep.Done), "first cycle should reach Done");

        // Advance past rebalance cooldown before starting second cycle
        vm.warp(block.timestamp + 1 hours);

        // --- Second rebalance: simulate unstaked funds arriving ---
        stakingManager.setUnstakedAmount(unstakeNeeded);
        asset.mint(address(stakingManager), unstakeNeeded);
        stakingManager.setWithdrawableUnstakes(0);
        stakingManager.setPendingUnstakes(0);
        stakingManager.setTotalStaked(0);

        // Run the second rebalance cycle to completion
        for (uint256 i; i < 10; ++i) {
            vm.prank(operator);
            core.rebalance();

            IOllaCore.RebalanceProgress memory pLoop = core.rebalanceProgress();
            if (pLoop.step == IOllaCore.RebalanceStep.Done) break;
        }

        IOllaCore.RebalanceProgress memory p2 = core.rebalanceProgress();
        assertEq(uint256(p2.step), uint256(IOllaCore.RebalanceStep.Done), "second cycle should reach Done");

        // Withdrawal should now be finalized — verify user can claim
        assertEq(withdrawalQueue.totalPendingAssets(), 0, "all pending withdrawals should be finalized");

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);
        assertEq(claimed, assetsExpected, "user should claim full withdrawal amount");
    }

    /*//////////////////////////////////////////////////////////////
               PAUSE LIFTS WHEN NO PENDING UNSTAKES
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests Change 2: completion is satisfied when `pending > 0 && buffer > 0`
    ///         but `pendingUnstakes == 0` (protocol has done all it can).
    function test_Rebalance_CompletesWhenNoPendingUnstakes() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 depositAmount = 50 * DECIMALS;
        uint256 allShares = _performDeposit(alice, depositAmount);
        _stakeAll(depositAmount);

        _injectBuffer(10 * DECIMALS);

        // Request withdrawal for more than buffer but less than total
        uint256 sharesToRedeem = core.convertToShares(30 * DECIMALS);
        if (sharesToRedeem > allShares) {
            sharesToRedeem = allShares;
        }
        (, uint256 assetsExpected) = _requestRedeem(alice, sharesToRedeem, alice);
        assertGt(assetsExpected, 10 * DECIMALS, "request should exceed buffer");

        // Rebalance through the full cycle
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setPendingUnstakes(0);

        for (uint256 i; i < 10; ++i) {
            vm.prank(operator);
            core.rebalance();

            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) break;
        }

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "should reach Done");

        // Rebalance should complete to Done
    }

    /*//////////////////////////////////////////////////////////////
              PAUSE STAYS WHEN PENDING UNSTAKES EXIST
    //////////////////////////////////////////////////////////////*/

    /// @notice When unstakes are in-flight, rebalance still reaches Done and
    ///         user operations (deposit) are not blocked.
    function test_Rebalance_CompletesAndAllowsDepositsWithPendingUnstakes() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 depositAmount = 50 * DECIMALS;
        uint256 allShares = _performDeposit(alice, depositAmount);
        _stakeAll(depositAmount);

        _injectBuffer(10 * DECIMALS);

        uint256 sharesToRedeem = core.convertToShares(30 * DECIMALS);
        if (sharesToRedeem > allShares) {
            sharesToRedeem = allShares;
        }
        (, uint256 assetsExpected) = _requestRedeem(alice, sharesToRedeem, alice);
        assertGt(assetsExpected, 10 * DECIMALS, "request should exceed buffer");

        // Set pendingUnstakes BEFORE the rebalance so the completion check reads it.
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setPendingUnstakes(20 * DECIMALS);

        for (uint256 i; i < 10; ++i) {
            vm.prank(operator);
            core.rebalance();

            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) break;
        }

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "should reach Done");

        // Deposits are allowed even with pending unstakes (no rebalance pause)
        asset.mint(alice, 1 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 1 * DECIMALS);
        vm.prank(alice);
        vault.deposit(1 * DECIMALS, alice, 0);
    }

    /*//////////////////////////////////////////////////////////////
          MULTIPLE SMALL REQUESTS: PARTIAL FINALIZE THEN ADVANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Edge case: buffer can finalize some requests but not the next one.
    ///         Verifies partial progress followed by advancement when stuck.
    function test_Rebalance_MultipleSmallRequests_PartialFinalizeThenAdvance() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        // Deposit enough to cover all redemption shares with margin
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);
        _stakeAll(depositAmount);

        // Inject 7 DECIMALS of buffer
        _injectBuffer(7 * DECIMALS);

        // Create 3 withdrawal requests of different sizes.
        // With totalAssets = 100 (staked) + 7 (buffer) = 107, and totalSupply = 100,
        // exchangeRate = 107/100 = 1.07, so convertToShares(2) = 2/1.07 ≈ 1.869
        // assetsExpected = shares * 107 / 100 (rounds down for each step).
        // Use convertToShares to get exact share amounts, then check assetsExpected.
        uint256 shares2 = core.convertToShares(2 * DECIMALS);
        uint256 shares3 = core.convertToShares(3 * DECIMALS);
        uint256 shares15 = core.convertToShares(15 * DECIMALS);

        (, uint256 ae1) = _requestRedeem(alice, shares2, alice);
        (, uint256 ae2) = _requestRedeem(alice, shares3, alice);
        (, uint256 ae3) = _requestRedeem(alice, shares15, alice);

        // Verify the setup: first two requests should fit in 7 DECIMALS buffer, third should not
        assertLe(ae1 + ae2, 7 * DECIMALS, "first two requests should fit in buffer");
        assertGt(ae3, 7 * DECIMALS - ae1 - ae2, "third request should NOT fit in remaining buffer");

        uint256 pendingBefore = withdrawalQueue.totalPendingAssets();
        assertEq(pendingBefore, ae1 + ae2 + ae3, "total pending matches sum of requests");

        // First rebalance: should finalize first two requests (ae1 + ae2), but not the third
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);

        vm.prank(operator);
        (, uint256 finalizedAmount,,) = core.rebalance();

        assertEq(finalizedAmount, ae1 + ae2, "should finalize first two requests");

        uint256 pendingAfterFirst = withdrawalQueue.totalPendingAssets();
        assertEq(pendingAfterFirst, ae3, "only third request remaining");

        // Second rebalance: buffer < ae3 → finalizedAmount = 0 → advances past FinalizeWithdrawals
        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertGt(
            uint256(progress.step),
            uint256(IOllaCore.RebalanceStep.FinalizeWithdrawals),
            "should advance past FinalizeWithdrawals after zero-progress iteration"
        );
    }

    /*//////////////////////////////////////////////////////////////
            ZERO FINALIZED ADVANCES TO INITIATE UNSTAKE
    //////////////////////////////////////////////////////////////*/

    /// @notice Simple, focused unit test for the exact condition change.
    ///         When FinalizeWithdrawals returns finalizedAmount = 0 while pending > 0 and buffer > 0,
    ///         the state machine must advance to InitiateUnstake.
    function test_Rebalance_ZeroFinalizedAdvancesToInitiateUnstake() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 depositAmount = 20 * DECIMALS;
        uint256 allShares = _performDeposit(alice, depositAmount);
        _stakeAll(depositAmount);

        // Create buffer of 4 DECIMALS
        _injectBuffer(4 * DECIMALS);

        // Request withdrawal for ~12 DECIMALS (exceeds 4 DECIMALS buffer)
        uint256 sharesToRedeem = core.convertToShares(12 * DECIMALS);
        if (sharesToRedeem > allShares) {
            sharesToRedeem = allShares;
        }
        (, uint256 assetsExpected) = _requestRedeem(alice, sharesToRedeem, alice);
        assertGt(assetsExpected, 4 * DECIMALS, "request should exceed buffer");

        assertEq(vault.bufferedAssets(), 4 * DECIMALS, "buffer should be 4 DECIMALS");

        // Rebalance
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();

        // State machine should have advanced to InitiateUnstake (step 3) or beyond
        assertGe(
            uint256(progress.step),
            uint256(IOllaCore.RebalanceStep.InitiateUnstake),
            "should advance to InitiateUnstake or beyond"
        );
    }

    /*//////////////////////////////////////////////////////////////
               IDLE GUARD AFTER UNPRODUCTIVE CYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures the fix doesn't break the idle guard for legitimate unproductive cycles.
    ///         When a cycle completes with no productive work, subsequent rebalance calls skip.
    function test_Rebalance_IdleGuardKicksInAfterUnproductiveCycles() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 depositAmount = 5 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Configure staking manager to return 0 (simulates below-minimum)
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setActivatedAttesterCount(0);

        // First rebalance: runs through all steps, nothing productive
        vm.prank(operator);
        core.rebalance();

        // Complete if multi-step
        for (uint256 i; i < 5; ++i) {
            IOllaCore.RebalanceProgress memory pLoop = core.rebalanceProgress();
            if (pLoop.step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        IOllaCore.RebalanceProgress memory p1 = core.rebalanceProgress();
        assertEq(uint256(p1.step), uint256(IOllaCore.RebalanceStep.Done), "first cycle should reach Done");

        uint256 bufferedAfterFirst = vault.bufferedAssets();
        assertGt(bufferedAfterFirst, 0, "should have buffered assets");

        // Advance past rebalance cooldown before calling rebalance again
        vm.warp(block.timestamp + 1 hours);

        // Second rebalance: should be a no-op (idle guard)
        vm.prank(operator);
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) =
            core.rebalance();

        assertEq(rewardsDelta, 0, "idle skip: rewardsDelta should be 0");
        assertEq(finalizedAmount, 0, "idle skip: finalizedAmount should be 0");
        assertEq(stakedAmount, 0, "idle skip: stakedAmount should be 0");
        assertEq(resultingBuffer, bufferedAfterFirst, "idle skip: buffer unchanged");

        IOllaCore.RebalanceProgress memory p2 = core.rebalanceProgress();
        assertEq(uint256(p2.step), uint256(IOllaCore.RebalanceStep.Done), "idle skip: still at Done");
    }
}
