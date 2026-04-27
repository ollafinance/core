// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { Exit, Timestamp } from "src/staking/libraries/AztecTypes.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerExitDelaySlashTest
/// @notice Tests the StakingManager's handling of exit delays and slashing during the exit
///         delay window. These scenarios model the real Aztec rollup behavior where:
///         1. initiateWithdraw creates an exit with a non-trivial delay (exitableAt in the future)
///         2. slash() can reduce exit.amount in-place during the delay window
///         3. finalizeWithdraw only succeeds after exitableAt passes
///
///         The existing test suite uses immediate exits (exitableAt = block.timestamp). These
///         tests fill the gap by exercising the timing-sensitive paths.
contract StakingManagerExitDelaySlashTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev 7-day exit delay matching typical Aztec rollup configuration.
    uint256 internal constant EXIT_DELAY = 7 days;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();
        // Enable non-trivial exit delay on the mock rollup
        rollup.setExitDelay(EXIT_DELAY);
    }

    /*//////////////////////////////////////////////////////////////
          NORMAL UNSTAKE WITH EXIT DELAY — FULL LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Normal unstake with exit delay: attester stays Exiting until delay passes,
    ///         then finalizes on the next refreshAttesterState call.
    function test_NormalUnstake_ExitDelay_FullLifecycle() external {
        _setupActiveAttester();
        address[] memory attesters = _attesterAddresses(1);

        // 1. Unstake — exit created with exitableAt = now + EXIT_DELAY
        vm.prank(core);
        uint256 unstaked = stakingManager.unstake(ACTIVATION_THRESHOLD);
        assertEq(unstaked, ACTIVATION_THRESHOLD, "unstake should return full threshold");

        // 2. Verify exit is NOT yet exitable on rollup
        Exit memory exitOnRollup = rollup.getExit(attesters[0]);
        assertTrue(exitOnRollup.exists, "exit should exist");
        assertGt(Timestamp.unwrap(exitOnRollup.exitableAt), block.timestamp, "exit should not be exitable yet");

        // 3. Refresh before delay passes — attester stays Exiting, no finalization
        stakingManager.refreshAttesterState(attesters);
        assertTrue(stakingManager.isUnstakePending(attesters[0]), "attester should still be Exiting");
        assertFalse(stakingManager.hasFinalizedUnstakes(), "no finalized unstakes yet");

        // 4. Warp past exit delay
        vm.warp(block.timestamp + EXIT_DELAY + 1);

        // 5. Refresh — now the exit is exitable, should finalize
        stakingManager.refreshAttesterState(attesters);
        assertFalse(stakingManager.isUnstakePending(attesters[0]), "attester should be finalized");
        assertTrue(stakingManager.hasFinalizedUnstakes(), "should have finalized unstakes");

        // 6. Claim funds
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(received, ACTIVATION_THRESHOLD, "should receive full threshold");
        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exit amount should match");
    }

    /// @notice Multiple attesters unstaked with delay — staggered finalization.
    function test_NormalUnstake_ExitDelay_StaggeredFinalization() external {
        _setupMultipleActiveAttesters(3);
        address[] memory attesters = _attesterAddresses(3);

        // Unstake all 3
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 3);

        // All should be Exiting
        assertEq(stakingManager.getPendingUnstakeCount(), 3, "all 3 should be Exiting");

        // Make attester[0] exitable sooner than others
        rollup.setExitReady(attesters[0], block.timestamp + 1 days);

        // Warp to attester[0]'s exit time
        vm.warp(block.timestamp + 1 days + 1);

        // Refresh — only attester[0] should finalize
        stakingManager.refreshAttesterState(attesters);
        assertEq(stakingManager.getPendingUnstakeCount(), 2, "2 still Exiting");

        // Warp past full delay for the other 2
        vm.warp(block.timestamp + EXIT_DELAY);
        stakingManager.refreshAttesterState(attesters);
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "all finalized");

        // Claim all
        vm.prank(core);
        (uint256 received,) = stakingManager.getUnstakedFunds();
        assertEq(received, ACTIVATION_THRESHOLD * 3, "should receive all 3 thresholds");
    }

    /*//////////////////////////////////////////////////////////////
        SLASH REDUCES EXIT AMOUNT DURING EXIT DELAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Slash during exit delay: exit.amount reduced in-place. A refresh before the exit
    ///         becomes exitable must immediately reconcile pendingUnstakeAmount and slashingDelta.
    function test_SlashDuringExitDelay_RefreshBeforeExitable_ReconcilesPendingUnstakeAmount() external {
        _setupActiveAttester();
        address[] memory attesters = _attesterAddresses(1);

        // 1. Unstake — exit with delay.
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory stateAfterUnstake = stakingManager.getStakingState();
        assertEq(stateAfterUnstake.pendingUnstakeAmount, ACTIVATION_THRESHOLD, "pending = threshold");
        assertEq(stakingManager.totalStaked(), ACTIVATION_THRESHOLD, "total staked includes pending exit");

        // 2. Slash during delay: reduce exit amount from 100 to 60 while the exit is still
        //    non-exitable. The rollup keeps the exit record, but mutates exit.amount in place.
        uint256 reducedAmount = 60 ether;
        uint256 expectedSlash = ACTIVATION_THRESHOLD - reducedAmount;
        rollup.reduceExitAmount(attesters[0], reducedAmount);

        Exit memory exitOnRollup = rollup.getExit(attesters[0]);
        assertTrue(exitOnRollup.exists, "exit should still exist");
        assertGt(Timestamp.unwrap(exitOnRollup.exitableAt), block.timestamp, "exit should not be exitable yet");
        assertEq(exitOnRollup.amount, reducedAmount, "exit amount should be reduced on rollup");

        // 3. Refresh before the exit is exitable. The regression is that current code does
        //    nothing in this intermediate state, leaving totalStaked inflated at 100 ether.
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfterRefresh = stakingManager.getStakingState();
        assertEq(stateAfterRefresh.pendingUnstakeAmount, reducedAmount, "pending unstake should track reduced exit");
        assertEq(stateAfterRefresh.slashingDelta, expectedSlash, "slashingDelta should record exit-delay slash");
        assertEq(stakingManager.totalStaked(), reducedAmount, "totalStaked should not overstate slashed pending exit");
        assertTrue(stakingManager.isUnstakePending(attesters[0]), "attester should remain Exiting");

        // 4. Later finalization should not double-count the slash. This also proves the fix
        //    updates the attester's pendingExitAmount snapshot when it reconciles the slash.
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfterFinalize = stakingManager.getStakingState();
        assertEq(stateAfterFinalize.pendingUnstakeAmount, 0, "pending unstake cleared after finalization");
        assertEq(stateAfterFinalize.slashingDelta, expectedSlash, "slash should not be double counted");

        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(received, reducedAmount, "received should equal reduced exit amount");
        assertEq(exitAmount, reducedAmount, "exitAmount should equal reduced exit amount");
    }

    /// @notice Slash during exit delay: exit.amount reduced in-place. Refresh before finalization
    ///         reads the correct reduced amount. This is the "happy path" where the keeper
    ///         calls refreshAttesterState promptly.
    function test_SlashDuringExitDelay_RefreshBeforeFinalize_CorrectAmount() external {
        _setupActiveAttester();
        address[] memory attesters = _attesterAddresses(1);

        // 1. Unstake — exit with delay
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory stateAfterUnstake = stakingManager.getStakingState();
        assertEq(stateAfterUnstake.pendingUnstakeAmount, ACTIVATION_THRESHOLD, "pending = threshold");

        // 2. Slash during delay: reduce exit amount from 100 to 60
        uint256 reducedAmount = 60 ether;
        rollup.reduceExitAmount(attesters[0], reducedAmount);

        // Verify mock state
        Exit memory exitOnRollup = rollup.getExit(attesters[0]);
        assertEq(exitOnRollup.amount, reducedAmount, "exit amount should be reduced on rollup");

        // 3. Warp past delay
        vm.warp(block.timestamp + EXIT_DELAY + 1);

        // 4. Refresh — should finalize at the REDUCED amount
        stakingManager.refreshAttesterState(attesters);
        assertFalse(stakingManager.isUnstakePending(attesters[0]), "attester should be finalized");

        // 5. Claim — should receive only the reduced amount
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(received, reducedAmount, "received should be the slashed amount");

        // When refresh finalizes an exitable exit (the normal path), it reads exit.amount
        // directly from the rollup (the reduced value). So exitAmount = actual reduced amount.
        assertEq(exitAmount, reducedAmount, "exitAmount reads reduced exit.amount from rollup");
    }

    /// @notice Slash during exit delay: the difference between what's received vs what
    ///         pendingExitAmount claims is the silent loss documented in StakingManager L595-609.
    ///         This test verifies the accounting is conservative (overstates the loss).
    function test_SlashDuringExitDelay_ExitableFinalize_ConservativeAccounting() external {
        _setupMultipleActiveAttesters(2);
        address[] memory attesters = _attesterAddresses(2);

        // 1. Unstake attester[1] (iterates from end)
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Find which attester was unstaked
        address unstaked = stakingManager.isUnstakePending(attesters[0]) ? attesters[0] : attesters[1];
        address active = unstaked == attesters[0] ? attesters[1] : attesters[0];

        // 2. Slash the exiting attester's exit during delay
        uint256 reducedAmount = 70 ether;
        rollup.reduceExitAmount(unstaked, reducedAmount);

        // 3. Warp past delay and finalize
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        stakingManager.refreshAttesterState(attesters);

        // 4. Verify: received == exitAmount (exitable path reads reduced amount)
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();

        // received = actual tokens from rollup (reduced)
        assertEq(received, reducedAmount, "received = actual slashed tokens");

        // exitAmount = view_.exit.amount (reduced) — the exitable path reads the rollup directly
        assertEq(exitAmount, reducedAmount, "exitAmount reads reduced amount from exitable exit");

        // The active attester should still be staked at full balance
        assertFalse(stakingManager.isUnstakePending(active), "active attester should remain active");
        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD, "active attester fully staked");
    }

    /// @notice Multiple sequential slashes during the exit delay. Each reduces exit.amount
    ///         further. Final finalization uses the last reduced amount.
    function test_MultipleSlashesDuringExitDelay() external {
        _setupActiveAttester();
        address[] memory attesters = _attesterAddresses(1);

        // 1. Unstake with delay
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // 2. First slash: 100 → 80
        rollup.reduceExitAmount(attesters[0], 80 ether);

        // 3. Second slash: 80 → 50
        rollup.reduceExitAmount(attesters[0], 50 ether);

        // 4. Warp and finalize
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        stakingManager.refreshAttesterState(attesters);

        // 5. Received = final reduced amount
        vm.prank(core);
        (uint256 received,) = stakingManager.getUnstakedFunds();
        assertEq(received, 50 ether, "received should be the final slashed amount");
    }

    /*//////////////////////////////////////////////////////////////
        EXTERNALLY FINALIZED EXIT WITH SLASH (CONCERN 1)
    //////////////////////////////////////////////////////////////*/

    /// @notice The worst case: attester is slashed during exit delay, then a third party
    ///         calls finalizeWithdraw on the rollup directly. When refreshAttesterState runs
    ///         afterward, the exit record is gone so it falls back to pendingExitAmount.
    ///         This test verifies the protocol does NOT revert and degrades gracefully.
    function test_SlashDuringExitDelay_ExternalFinalize_PendingClaimOverstated() external {
        _setupActiveAttester();
        address[] memory attesters = _attesterAddresses(1);

        // 1. Unstake with delay
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "1 exiting");

        // 2. Slash during delay: 100 → 60
        uint256 reducedAmount = 60 ether;
        rollup.reduceExitAmount(attesters[0], reducedAmount);

        // 3. Warp past delay
        vm.warp(block.timestamp + EXIT_DELAY + 1);

        // 4. Third party finalizes directly on rollup (bypasses StakingManager)
        rollup.finalizeWithdraw(attesters[0]);

        // At this point:
        // - Rollup sent 60 ether to StakingManager (the reduced amount)
        // - Exit record deleted on rollup
        // - StakingManager still thinks pendingExitAmount = 100 ether

        // 5. Refresh detects no exit record for Exiting attester → reconciles using pendingExitAmount
        stakingManager.refreshAttesterState(attesters);

        assertFalse(stakingManager.isUnstakePending(attesters[0]), "attester removed after reconcile");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no pending unstakes");

        // 6. Claim funds
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();

        // received = actual balance = 60 ether (what rollup actually sent)
        assertEq(received, reducedAmount, "received = actual tokens on hand");

        // exitAmount = pendingExitAmount = 100 ether (overstated — the documented concern)
        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exitAmount overstated from stale pendingExitAmount");

        // The key invariant: received <= exitAmount. OllaCore's _pullUnstakedFunds
        // uses exitAmount to reduce stakedPrincipal, so the protocol UNDERSTATES its
        // total assets (conservative). This is safe — no phantom credit created.
        assertLe(received, exitAmount, "received must never exceed exitAmount");
    }

    /*//////////////////////////////////////////////////////////////
        ZOMBIE EXIT WITH EXIT DELAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Zombie exit with non-trivial delay: first refresh claims the zombie,
    ///         second refresh (after delay) finalizes.
    function test_ZombieExit_WithExitDelay_TwoPhaseFinalization() external {
        _setupActiveAttester();
        address[] memory attesters = _attesterAddresses(1);

        // Create zombie exit with future exitableAt
        rollup.setExternalExit(attesters[0], ACTIVATION_THRESHOLD, block.timestamp + EXIT_DELAY);

        // Phase 1: Refresh claims zombie (sets isRecipient=true)
        stakingManager.refreshAttesterState(attesters);
        assertTrue(stakingManager.isUnstakePending(attesters[0]), "should be Exiting after claim");
        Exit memory claimed = rollup.getExit(attesters[0]);
        assertTrue(claimed.isRecipient, "should be claimed (isRecipient=true)");

        // Still not exitable
        assertFalse(stakingManager.hasFinalizedUnstakes(), "not finalized yet");

        // Phase 2: Warp past delay, refresh finalizes
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        stakingManager.refreshAttesterState(attesters);
        assertFalse(stakingManager.isUnstakePending(attesters[0]), "should be finalized");

        vm.prank(core);
        (uint256 received,) = stakingManager.getUnstakedFunds();
        assertEq(received, ACTIVATION_THRESHOLD, "full amount received");
    }

    /// @notice Zombie exit slashed during delay: reduced amount recovered.
    function test_ZombieExit_SlashedDuringExitDelay() external {
        _setupActiveAttester();
        address[] memory attesters = _attesterAddresses(1);

        // Create zombie exit (partial slash: 100 → 75)
        uint256 exitAmount = 75 ether;
        rollup.setExternalExit(attesters[0], exitAmount, block.timestamp + EXIT_DELAY);

        // Phase 1: Claim zombie
        stakingManager.refreshAttesterState(attesters);
        assertTrue(stakingManager.isUnstakePending(attesters[0]), "Exiting after claim");

        // Additional slash during delay: 75 → 50
        rollup.reduceExitAmount(attesters[0], 50 ether);

        // Phase 2: Warp and finalize
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        stakingManager.refreshAttesterState(attesters);

        vm.prank(core);
        (uint256 received,) = stakingManager.getUnstakedFunds();
        assertEq(received, 50 ether, "received = final reduced amount after double slash");

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        // slashingDelta records BOTH slashes:
        // - initial slash (100 → 75 = 25) detected at zombie detection time
        // - exit-delay slash (75 → 50 = 25) detected at exitable finalization
        uint256 expectedDelta = (ACTIVATION_THRESHOLD - exitAmount) + (exitAmount - 50 ether);
        assertEq(state.slashingDelta, expectedDelta, "slashingDelta = initial + exit-delay slash");
    }

    /*//////////////////////////////////////////////////////////////
                 MIXED SCENARIO: ACTIVE + EXITING SLASHES
    //////////////////////////////////////////////////////////////*/

    /// @notice One attester is slashed while active (balance reduced, no exit), another is
    ///         slashed while exiting (exit.amount reduced during delay). Both losses should
    ///         be reflected in the final accounting.
    function test_MixedActiveAndExitingSlash() external {
        _setupMultipleActiveAttesters(3);
        address[] memory attesters = _attesterAddresses(3);

        // 1. Unstake attester[2] (iterates from end)
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Find the exiting attester
        address exitingAttester;
        for (uint256 i; i < 3; ++i) {
            if (stakingManager.isUnstakePending(attesters[i])) {
                exitingAttester = attesters[i];
                break;
            }
        }

        // 2. Slash active attester[0]: reduce balance from 100 to 70 (no exit)
        rollup.setStake(attesters[0], 70 ether, address(stakingManager));

        // 3. Slash exiting attester: reduce exit amount from 100 to 80
        rollup.reduceExitAmount(exitingAttester, 80 ether);

        // 4. Refresh to detect active slash
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfterRefresh = stakingManager.getStakingState();
        // Both the active slash (30 ether) and the pre-exitable exit slash (20 ether)
        // should be reflected immediately on refresh.
        assertEq(stateAfterRefresh.slashingDelta, 50 ether, "active and exiting slashes tracked in slashingDelta");
        assertEq(stateAfterRefresh.pendingUnstakeAmount, 80 ether, "pending unstake reconciled before finalization");

        // 5. Warp past delay and finalize exit
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        stakingManager.refreshAttesterState(attesters);

        // 6. Claim — exiting attester returns 80 (not 100)
        vm.prank(core);
        (uint256 received,) = stakingManager.getUnstakedFunds();
        assertEq(received, 80 ether, "received = slashed exit amount");

        // Active attester still staked at reduced balance
        IStakingManager.StakingState memory finalState = stakingManager.getStakingState();
        // attester[0] at 70 + attester[1] at 100 = 170
        assertEq(finalState.stakedAmount, 170 ether, "2 active attesters at correct balances");
    }

    /*//////////////////////////////////////////////////////////////
                FUZZ: SLASH PERCENTAGE DURING EXIT DELAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz: any slash percentage during exit delay produces valid accounting.
    function testFuzz_SlashDuringExitDelay(uint256 slashedAmount) external {
        slashedAmount = bound(slashedAmount, 0, ACTIVATION_THRESHOLD);

        _setupActiveAttester();
        address[] memory attesters = _attesterAddresses(1);

        // Unstake with delay
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Slash during delay
        rollup.reduceExitAmount(attesters[0], slashedAmount);

        // Warp and finalize
        vm.warp(block.timestamp + EXIT_DELAY + 1);
        stakingManager.refreshAttesterState(attesters);

        // Claim
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();

        // received = actual tokens from rollup
        assertEq(received, slashedAmount, "received = slashed amount");

        // exitAmount = view_.exit.amount (reduced) — exitable path reads rollup directly
        assertEq(exitAmount, slashedAmount, "exitAmount = reduced amount from rollup");

        // Safety invariant: received == exitAmount for the normal exitable path
        assertEq(received, exitAmount, "received equals exitAmount for exitable finalization");
    }
}
