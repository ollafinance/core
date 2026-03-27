// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Vm } from "@forge-std/Test.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MaliciousAztecRollup } from "src/staking/mocks/MaliciousAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerRefreshAttesterStateTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                    REFRESH ATTESTER STATE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone can call refreshAttesterState() - it has no access control.
    function test_RefreshAttesterState_PermissionlessAccess() external {
        _setupActiveAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Call refreshAttesterState() from a random address (not core, not operator, not admin)
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending unstake should be cleared");
    }

    /// @notice When there are no exiting attesters, refreshAttesterState() is a no-op.
    function test_RefreshAttesterState_NoOp_WhenNoExitableAttesters() external {
        // No attesters registered or staked at all -- should not revert
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // With staked attesters but none unstaking -- should not revert
        _setupActiveAttester();
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getActivatedAttesterCount(), 1, "active count should be unchanged");
    }

    /// @notice refreshAttesterState() tracks the finalized amount in _pendingClaimAmount,
    ///         which is then returned as exitAmount by getUnstakedFunds().
    function test_RefreshAttesterState_TracksPendingClaimAmount() external {
        _setupActiveAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // getUnstakedFunds should report exitAmount equal to what was finalized
        vm.prank(core);
        (, uint256 exitAmount) = stakingManager.getUnstakedFunds();

        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exitAmount should match the finalized amount");
    }

    /// @notice Multiple calls to refreshAttesterState() accumulate _pendingClaimAmount
    ///         until getUnstakedFunds() drains it.
    function test_RefreshAttesterState_AccumulatesAcrossMultipleCalls() external {
        _setupMultipleActiveAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        // Unstake both attesters
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        // Make only the second attester exitable initially
        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        // First refreshAttesterState: only attester[1] is exitable
        stakingManager.refreshAttesterState(_attesterAddresses(2));
        vm.prank(core);
        (, uint256 firstExitAmount) = stakingManager.getUnstakedFunds();
        assertEq(firstExitAmount, ACTIVATION_THRESHOLD, "first call should finalize one attester");

        // Advance time so attester[0] becomes exitable
        vm.warp(block.timestamp + 2 days);

        // Second refreshAttesterState: attester[0] now exitable
        stakingManager.refreshAttesterState(_attesterAddresses(2));
        vm.prank(core);
        (, uint256 secondExitAmount) = stakingManager.getUnstakedFunds();
        assertEq(secondExitAmount, ACTIVATION_THRESHOLD, "second call should finalize remaining attester");
    }

    /// @notice getUnstakedFunds() returns exitAmount matching _pendingClaimAmount and resets it to 0.
    ///         A subsequent call to getUnstakedFunds() should return exitAmount=0.
    function test_GetUnstakedFunds_ReturnsExitAmountAndResetsIt() external {
        _setupActiveAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // First getUnstakedFunds: should return exitAmount matching finalized amount
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();

        assertEq(exitAmount, ACTIVATION_THRESHOLD, "first call exitAmount should match finalized amount");
        assertEq(received, ACTIVATION_THRESHOLD, "first call received should include finalized tokens");

        // Second getUnstakedFunds: _pendingClaimAmount was reset, so exitAmount should be 0
        vm.prank(core);
        (uint256 receivedSecond, uint256 exitAmountSecond) = stakingManager.getUnstakedFunds();

        assertEq(exitAmountSecond, 0, "second call exitAmount should be 0 after reset");
        assertEq(receivedSecond, 0, "second call received should be 0 with no balance remaining");
    }

    /// @notice Tokens sent directly to StakingManager (donations) are swept by getUnstakedFunds()
    ///         as `received` but are NOT counted as `exitAmount`.
    function test_GetUnstakedFunds_DonationSweptAsReceivedNotExitAmount() external {
        uint256 donationAmount = 50 ether;

        // Mint tokens to alice and have alice send them directly to StakingManager (donation)
        aztec.mint(alice, donationAmount);
        vm.prank(alice);
        aztec.transfer(address(stakingManager), donationAmount);

        assertEq(aztec.balanceOf(address(stakingManager)), donationAmount, "manager should hold donated tokens");

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        // getUnstakedFunds should sweep the donation as `received` but exitAmount should be 0
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();

        assertEq(received, donationAmount, "received should include donated tokens");
        assertEq(exitAmount, 0, "exitAmount should be 0 since no exits were finalized");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + donationAmount, "core should receive donated tokens");
        assertEq(aztec.balanceOf(address(stakingManager)), 0, "manager should have zero balance after sweep");
    }

    /*//////////////////////////////////////////////////////////////
            EXTERNALLY FINALIZED ACTIVE ATTESTER RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice An active attester that was externally fully exited (zero balance, no exit record)
    ///         should be removed during refreshAttesterState.
    function test_RefreshAttesterState_RemovesExternallyFinalizedActiveAttester() external {
        _setupActiveAttester();
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "should have 1 active attester");

        // Simulate external full exit: zero balance but config still present on the GSE
        // (withdrawer persists after exit on the real rollup).
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        rollup.clearAttester(keys[0].attester);
        rollup.setStake(keys[0].attester, 0, address(stakingManager));

        // Refresh should detect zero balance + no exit and remove the attester
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "active count should be 0 after removal");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending unstake count should be 0 after removal");
    }

    /// @notice When an externally finalized active attester is removed, the aggregate stakedAmount
    ///         should be decremented by the attester's cached balance.
    function test_RefreshAttesterState_ExternallyFinalizedUpdatesAggregateState() external {
        _setupMultipleActiveAttesters(2);
        assertEq(stakingManager.getActivatedAttesterCount(), 2, "should have 2 active attesters");

        // Externally finalize only the first attester (config persists on real rollup)
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        rollup.clearAttester(keys[0].attester);
        rollup.setStake(keys[0].attester, 0, address(stakingManager));

        stakingManager.refreshAttesterState(_attesterAddresses(2));

        assertEq(stakingManager.getActivatedAttesterCount(), 1, "active count should be 1");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending unstake count should be 0");
    }

    /*//////////////////////////////////////////////////////////////
            EXTERNALLY FINALIZED EXIT ACCOUNTING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice When a third party calls rollup.finalizeWithdraw() directly (bypassing StakingManager),
    ///         the subsequent refreshAttesterState() must reconcile pendingUnstakeAmount and
    ///         populate _pendingClaimAmount so OllaCore can reduce stakedPrincipal.
    function test_RefreshAttesterState_ExternalFinalization_ReconcilesPendingUnstake() external {
        _setupActiveAttester();

        // Unstake via StakingManager -- creates exit on rollup, increments pendingUnstakeAmount
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory stateAfterUnstake = stakingManager.getStakingState();
        assertEq(stateAfterUnstake.pendingUnstakeAmount, ACTIVATION_THRESHOLD, "pending should be set after unstake");

        // Third party calls finalizeWithdraw directly on the rollup
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        rollup.finalizeWithdraw(keys[0].attester);

        // Now the exit record is gone on the rollup, but StakingManager still tracks pendingUnstakeAmount
        IStakingManager.StakingState memory stateBeforeRefresh = stakingManager.getStakingState();
        assertEq(
            stateBeforeRefresh.pendingUnstakeAmount,
            ACTIVATION_THRESHOLD,
            "pending should still be stale before refresh"
        );

        // Refresh detects the externally finalized exit and reconciles
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        IStakingManager.StakingState memory stateAfterRefresh = stakingManager.getStakingState();
        assertEq(stateAfterRefresh.pendingUnstakeAmount, 0, "pending should be cleared after reconciliation");

        // _pendingClaimAmount should be populated for OllaCore to claim
        vm.prank(core);
        (, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exitAmount should match the externally finalized amount");
    }

    /// @notice When an externally initiated exit (detected via refresh as Active -> Exiting)
    ///         is later externally finalized, pendingUnstakeAmount must still be reconciled.
    function test_RefreshAttesterState_ExternalInitiateAndFinalize_ReconcilesFully() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        // External party initiates an exit on the rollup with a future exitable time
        // so the first refresh only detects the exit without immediately finalizing it.
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        // First refresh: detects Active attester with exit -> transitions to Exiting, increments pendingUnstake
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        IStakingManager.StakingState memory stateAfterDetection = stakingManager.getStakingState();
        assertEq(
            stateAfterDetection.pendingUnstakeAmount,
            ACTIVATION_THRESHOLD,
            "pending should be set after detecting external exit"
        );

        // External party finalizes the exit on the rollup (clears exit record)
        rollup.clearAttester(keys[0].attester);

        // Second refresh: detects Exiting attester with no exit -> reconciles and removes
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        IStakingManager.StakingState memory stateAfterReconcile = stakingManager.getStakingState();
        assertEq(stateAfterReconcile.pendingUnstakeAmount, 0, "pending should be cleared after reconciliation");

        vm.prank(core);
        (, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exitAmount should be populated for OllaCore");
    }

    /// @notice totalStaked() remains consistent through the external finalization lifecycle.
    function test_RefreshAttesterState_ExternalFinalization_TotalStakedConsistent() external {
        _setupMultipleActiveAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        uint256 initialTotal = stakingManager.totalStaked();
        assertEq(initialTotal, ACTIVATION_THRESHOLD * 2, "initial total should be 2x threshold");

        // Unstake one attester (picks from end of set, so keys[1] gets unstaked)
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // totalStaked should remain 2x (stakedAmount + pendingUnstakeAmount)
        assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD * 2, "total should be unchanged after unstake");

        // External finalization of the unstaked attester (keys[1] -- the one that was unstaked)
        rollup.finalizeWithdraw(keys[1].attester);

        // Refresh reconciles the accounting
        stakingManager.refreshAttesterState(_attesterAddresses(2));

        // After reconciliation: stakedAmount for 1 active + pendingClaim for 1 finalized
        assertEq(
            stakingManager.totalStaked(),
            ACTIVATION_THRESHOLD * 2,
            "total should still be 2x (1 staked + 1 pending claim)"
        );

        // After claiming, total should drop
        vm.prank(core);
        stakingManager.getUnstakedFunds();
        assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD, "total should be 1x after claim");
    }

    /*//////////////////////////////////////////////////////////////
        HASEXITABLEUNSTAKES / WORK DETECTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice hasFinalizedUnstakes() returns true after refresh finalizes an exit,
    ///         enabling _hasRebalanceWorkAvailable() in OllaCore to detect work.
    function test_HasFinalizedUnstakes_TrueAfterRefreshFinalizesExit() external {
        _setupActiveAttester();

        assertFalse(stakingManager.hasFinalizedUnstakes(), "should be false initially");

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        assertFalse(stakingManager.hasFinalizedUnstakes(), "should be false after unstake but before refresh");

        // Refresh finalizes the exit (mock sets exitableAt = block.timestamp)
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertTrue(stakingManager.hasFinalizedUnstakes(), "should be true after refresh finalizes exit");
    }

    /// @notice hasFinalizedUnstakes() returns false after getUnstakedFunds drains _pendingClaimAmount.
    function test_HasFinalizedUnstakes_FalseAfterClaim() external {
        _setupActiveAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertTrue(stakingManager.hasFinalizedUnstakes(), "should be true after finalization");

        vm.prank(core);
        stakingManager.getUnstakedFunds();

        assertFalse(stakingManager.hasFinalizedUnstakes(), "should be false after claim");
    }

    /// @notice hasFinalizedUnstakes() returns true for externally finalized exits too.
    function test_HasFinalizedUnstakes_TrueAfterExternalFinalization() external {
        _setupActiveAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // External finalization
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        rollup.finalizeWithdraw(keys[0].attester);

        assertFalse(
            stakingManager.hasFinalizedUnstakes(), "should be false before refresh detects external finalization"
        );

        // Refresh detects and reconciles
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertTrue(
            stakingManager.hasFinalizedUnstakes(), "should be true after refresh reconciles external finalization"
        );
    }

    /*//////////////////////////////////////////////////////////////
            QUEUED ATTESTER PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A Queued attester whose rollup returns NONE (not yet flushed) stays Queued.
    ///         refreshAttesterState() must not remove or promote it.
    function test_RefreshAttesterState_SkipsQueuedAttester() external {
        // Stake creates a Queued attester. Clear rollup state to simulate
        // "deposited but not yet flushed into the GSE."
        _setupStakedAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        rollup.clearAttester(keys[0].attester);
        rollup.setStake(keys[0].attester, 0, address(0));

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        // Refresh should skip -- attester is Queued and rollup is NONE
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "active count must be 0 (still Queued)");
        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, stateBefore.stakedAmount, "stakedAmount must not change");
        assertEq(stateAfter.slashingDelta, stateBefore.slashingDelta, "slashingDelta must not change");
    }

    /// @notice After the queue is flushed (attester becomes VALIDATING), refreshAttesterState
    ///         promotes Queued -> Active.
    function test_RefreshAttesterState_WorksAfterQueueFlush() external {
        // Stake creates a Queued attester. The mock rollup already has the attester
        // as VALIDATING (deposit sets stakes > 0), so refresh promotes immediately.
        _setupStakedAttester();

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "attester should be Queued before refresh");

        // Refresh promotes Queued -> Active
        stakingManager.refreshAttesterState(_attesterAddresses(1));
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester should be active after flush");
    }

    /// @notice Multiple refreshes on a Queued attester with NONE status should all be no-ops.
    function test_RefreshAttesterState_MultipleRefreshesWhileQueued() external {
        _setupStakedAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        // Clear rollup to simulate not-yet-flushed
        rollup.clearAttester(keys[0].attester);
        rollup.setStake(keys[0].attester, 0, address(0));

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        // Multiple refreshes
        stakingManager.refreshAttesterState(_attesterAddresses(1));
        stakingManager.refreshAttesterState(_attesterAddresses(1));
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "active count must stay 0 (still Queued)");
        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, stateBefore.stakedAmount, "stakedAmount must not change");
        assertEq(stateAfter.slashingDelta, stateBefore.slashingDelta, "slashingDelta must not change");
    }

    /// @notice An Active attester with zero balance and no exit is treated as externally
    ///         fully exited and should be removed.
    function test_RefreshAttesterState_StillRemovesExternallyExitedWithConfig() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        // Simulate external full exit: zero balance but config still present
        // (withdrawer is non-zero because the GSE set it during activation).
        rollup.setStake(keys[0].attester, 0, address(stakingManager));

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "externally exited attester should be removed");
    }

    /*//////////////////////////////////////////////////////////////
            PARTIAL SLASH (NON-ZERO BALANCE, NO EXIT) TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice An active attester whose rollup balance decreases (partial slash) but remains
    ///         non-zero should stay Active with updated cached balance. stakedAmount decreases
    ///         and slashingDelta increases by the slashed amount.
    /// @dev    Reachable on Aztec: StakingLib.slash() when effectiveBalance - slashAmount >=
    ///         localEjectionThreshold. The attester stays VALIDATING in the GSE with reduced
    ///         effectiveBalance and no exit record is created.
    function test_RefreshAttesterState_PartialSlash_AttesterStaysActive() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();
        assertEq(stateBefore.stakedAmount, ACTIVATION_THRESHOLD, "pre: stakedAmount = threshold");
        assertEq(stateBefore.slashingDelta, 0, "pre: slashingDelta = 0");

        // Reduce the attester's balance on rollup to 60% (partial slash, no exit)
        uint256 slashedBalance = ACTIVATION_THRESHOLD * 60 / 100;
        uint256 slashLoss = ACTIVATION_THRESHOLD - slashedBalance;
        rollup.setStake(attester, slashedBalance, address(stakingManager));

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // Attester should remain Active
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester should remain active");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no pending unstakes");

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, slashedBalance, "stakedAmount should decrease to slashed balance");
        assertEq(stateAfter.slashingDelta, slashLoss, "slashingDelta should track the slash loss");
    }

    /// @notice After a partial slash, a second refresh with no further rollup changes should be
    ///         a no-op (cached balance matches rollup, delta is zero).
    function test_RefreshAttesterState_PartialSlash_SecondRefreshIsNoOp() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;

        // Partial slash
        uint256 slashedBalance = 70 ether;
        rollup.setStake(attester, slashedBalance, address(stakingManager));
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        IStakingManager.StakingState memory stateAfterFirst = stakingManager.getStakingState();

        // Second refresh -- no rollup changes
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        IStakingManager.StakingState memory stateAfterSecond = stakingManager.getStakingState();
        assertEq(stateAfterSecond.stakedAmount, stateAfterFirst.stakedAmount, "stakedAmount unchanged");
        assertEq(stateAfterSecond.slashingDelta, stateAfterFirst.slashingDelta, "slashingDelta unchanged");
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester still active");
    }

    /*//////////////////////////////////////////////////////////////
            ALREADY-CLAIMED EXTERNAL EXIT (isRecipient=true) TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice When an external exit already has isRecipient=true (claimed by another party),
    ///         refreshAttesterState should skip the initiateWithdraw call and still transition
    ///         the attester to Exiting correctly.
    /// @dev    DEFENSIVE TEST -- not reachable on the current Aztec rollup. On Aztec,
    ///         initiateWithdraw() requires msg.sender == withdrawer (= StakingManager), so no
    ///         third party can create an isRecipient=true exit without the StakingManager's
    ///         involvement. This test guards against future Aztec rollup changes where a
    ///         different actor could set isRecipient=true (e.g. governance-driven forced exits).
    function test_RefreshAttesterState_AlreadyClaimedExternalExit() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;

        // Create an external exit that is already claimed (isRecipient=true)
        rollup.setExternalExit(attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);
        rollup.setExitRecipient(attester, address(stakingManager));

        // Refresh should detect the exit and transition to Exiting without calling initiateWithdraw
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "active count should be 0");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "should have 1 pending unstake");
        assertTrue(stakingManager.isUnstakePending(attester), "attester should be Exiting");

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.pendingUnstakeAmount, ACTIVATION_THRESHOLD, "pendingUnstake should match exit amount");
        assertEq(state.slashingDelta, 0, "no slashing delta for full recovery");
    }

    /// @notice An already-claimed external exit that is immediately exitable should be
    ///         finalized in a single refresh call (same as zombie, but without initiateWithdraw).
    /// @dev    DEFENSIVE TEST -- see test_RefreshAttesterState_AlreadyClaimedExternalExit for
    ///         reachability notes.
    function test_RefreshAttesterState_AlreadyClaimedExternalExit_ImmediateFinalization() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;

        // Create an external exit that is already claimed and immediately exitable
        rollup.setExternalExit(attester, ACTIVATION_THRESHOLD, block.timestamp);
        rollup.setExitRecipient(attester, address(stakingManager));

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // Should be fully finalized
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "no active attesters");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no pending unstakes (finalized)");

        // Funds claimable
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(received, ACTIVATION_THRESHOLD, "funds should be received");
        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exit amount should be claimable");
    }

    /*//////////////////////////////////////////////////////////////
                    IDEMPOTENT REFRESH TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calling refreshAttesterState twice for an Active+VALIDATING attester with
    ///         no rollup state changes should leave all aggregate state exactly unchanged.
    function test_RefreshAttesterState_IdempotentForActiveValidating() external {
        _setupMultipleActiveAttesters(2);

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();
        uint256 activeCountBefore = stakingManager.getActivatedAttesterCount();

        // First refresh -- should be no-op
        stakingManager.refreshAttesterState(_attesterAddresses(2));

        IStakingManager.StakingState memory stateAfterFirst = stakingManager.getStakingState();
        assertEq(stateAfterFirst.stakedAmount, stateBefore.stakedAmount, "stakedAmount unchanged after 1st");
        assertEq(stateAfterFirst.slashingDelta, stateBefore.slashingDelta, "slashingDelta unchanged after 1st");
        assertEq(stateAfterFirst.pendingUnstakeAmount, stateBefore.pendingUnstakeAmount, "pending unchanged after 1st");

        // Second refresh -- should also be no-op
        stakingManager.refreshAttesterState(_attesterAddresses(2));

        IStakingManager.StakingState memory stateAfterSecond = stakingManager.getStakingState();
        assertEq(stateAfterSecond.stakedAmount, stateBefore.stakedAmount, "stakedAmount unchanged after 2nd");
        assertEq(stateAfterSecond.slashingDelta, stateBefore.slashingDelta, "slashingDelta unchanged after 2nd");
        assertEq(stateAfterSecond.pendingUnstakeAmount, stateBefore.pendingUnstakeAmount, "pending unchanged after 2nd");
        assertEq(stakingManager.getActivatedAttesterCount(), activeCountBefore, "active count unchanged after 2nd");
    }

    /*//////////////////////////////////////////////////////////////
                REFRESH ATTESTER STATE REENTRANCY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice refreshAttesterState() is protected by nonReentrant. Re-entering via the rollup's
    ///         finalizeWithdraw() callback reverts with ReentrancyGuardReentrantCall.
    function test_RevertWhen_RefreshAttesterState_Reentrancy() external {
        // Deploy a malicious rollup that re-enters during finalizeWithdraw
        MaliciousAztecRollup maliciousRollup = new MaliciousAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        MockAztecRollupRegistry maliciousRegistry = new MockAztecRollupRegistry(address(maliciousRollup));
        MockRewardsAccumulator maliciousRewardsAccumulator = new MockRewardsAccumulator(IERC20(address(aztec)), core);

        // Deploy a fresh StakingManager wired to the malicious rollup
        StakingManager maliciousSM = StakingManager(address(new ERC1967Proxy(address(new StakingManager()), "")));

        StakingProviderRegistry maliciousRegistry2 =
            StakingProviderRegistry(address(new ERC1967Proxy(address(new StakingProviderRegistry()), "")));
        maliciousRegistry2.initialize(address(maliciousSM), providerAdmin, providerAdmin, defaultAdmin);

        maliciousSM.initialize(
            IERC20(address(aztec)),
            address(maliciousRegistry),
            address(maliciousRewardsAccumulator),
            core,
            address(maliciousRegistry2),
            defaultAdmin
        );

        // Stake one attester
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        maliciousRegistry2.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(maliciousSM), ACTIVATION_THRESHOLD);
        maliciousSM.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // Promote Queued -> Active so unstake can find the attester
        maliciousSM.refreshAttesterState(_attesterAddresses(1));

        // Unstake to put attester into exiting state
        vm.prank(core);
        maliciousSM.unstake(ACTIVATION_THRESHOLD);

        // Configure the malicious rollup to re-enter refreshAttesterState during finalizeWithdraw
        address[] memory reentrancyAttesters = _attesterAddresses(1);
        maliciousRollup.setReentry(
            address(maliciousSM), abi.encodeCall(maliciousSM.refreshAttesterState, (reentrancyAttesters))
        );
        maliciousRollup.setReenterOnFinalizeWithdraw(true);

        // The reentrancy attempt should revert
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        maliciousSM.refreshAttesterState(reentrancyAttesters);
    }
}
