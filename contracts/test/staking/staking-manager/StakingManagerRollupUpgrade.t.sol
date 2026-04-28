// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerRollupUpgradeTest
/// @notice Tests that exiting attesters survive a rollup upgrade without phantom credits or stranded funds.
contract StakingManagerRollupUpgradeTest is StakingManagerBaseTest {
    MockAztecRollup internal rollupB;
    MockAztecRollup internal rollupC;

    function setUp() public override {
        super.setUp();
        // Deploy a second rollup instance to simulate an upgrade
        rollupB = new MockAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        rollupC = new MockAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
    }

    function _setRollupRewards(MockAztecRollup targetRollup, uint256 amount) internal {
        aztec.mint(address(targetRollup), amount);
        targetRollup.setRewards(address(rewardsAccumulator), amount);
    }

    /*//////////////////////////////////////////////////////////////
                    ROLLUP UPGRADE -- EXITING ATTESTER
    //////////////////////////////////////////////////////////////*/

    /// @notice Core scenario: an attester has an in-flight exit on rollup A when the registry
    ///         upgrades to rollup B. refreshAttesterState must still query rollup A for the exit
    ///         and must NOT credit a phantom exit amount just because rollup B has no exit record.
    function test_RefreshAttesterState_ExitingAttester_SurvivesRollupUpgrade() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;

        // 1. Initiate unstake on rollup A -- attester transitions to Exiting
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        assertTrue(stakingManager.isUnstakePending(attester), "attester should be exiting");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "exiting count should be 1");

        // 2. Make the exit NOT yet exitable (future timestamp) so it stays pending
        rollup.setExitReady(attester, block.timestamp + 1 days);

        // 3. Simulate rollup upgrade: registry now points to rollup B
        rollupRegistry.setCanonicalRollup(address(rollupB));

        // 4. Refresh -- should query rollup A (stored exitRollup), NOT rollup B
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // The attester must still be in Exiting state -- NOT removed with a phantom credit
        assertTrue(stakingManager.isUnstakePending(attester), "attester should still be exiting after upgrade");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "exiting count should still be 1");

        // No phantom funds should be credited
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(exitAmount, 0, "exitAmount should be 0 -- no phantom credit");
        assertEq(received, 0, "received should be 0 -- no funds transferred");
    }

    /// @notice After a rollup upgrade, once the exit on rollup A becomes exitable,
    ///         refreshAttesterState must finalize it on rollup A and recover the funds.
    function test_RefreshAttesterState_ExitingAttester_FinalizesOnOldRollupAfterUpgrade() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;

        // 1. Initiate unstake on rollup A
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // 2. Make exit not yet exitable
        rollup.setExitReady(attester, block.timestamp + 1 days);

        // 3. Upgrade to rollup B
        rollupRegistry.setCanonicalRollup(address(rollupB));

        // 4. Advance time so exit becomes exitable on rollup A
        vm.warp(block.timestamp + 2 days);

        // 5. Refresh -- should finalize on rollup A
        uint256 managerBalanceBefore = aztec.balanceOf(address(stakingManager));
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // Attester should be removed now
        assertFalse(stakingManager.isUnstakePending(attester), "attester should no longer be exiting");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "exiting count should be 0");

        // Funds should have arrived at StakingManager from rollup A
        uint256 managerBalanceAfter = aztec.balanceOf(address(stakingManager));
        assertEq(
            managerBalanceAfter - managerBalanceBefore,
            ACTIVATION_THRESHOLD,
            "funds should be transferred from old rollup"
        );

        // Core can claim the funds
        uint256 coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();

        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exitAmount should match finalized amount");
        assertEq(received, ACTIVATION_THRESHOLD, "received should match transferred tokens");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD, "core should receive funds");
    }

    /// @notice Mixed scenario: one attester is active (follows upgrade), one is exiting (stays on old rollup).
    ///         After upgrade, active attester works on rollup B, exiting attester finalizes on rollup A.
    function test_RefreshAttesterState_MixedActiveAndExiting_AfterUpgrade() external {
        _setupMultipleActiveAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        address activeAttester = keys[0].attester;
        address exitingAttester = keys[1].attester;

        // Unstake one attester (picks from end of set → keys[1])
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        assertTrue(stakingManager.isUnstakePending(exitingAttester), "attester[1] should be exiting");
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "1 active attester remains");

        // Make exit not yet exitable
        rollup.setExitReady(exitingAttester, block.timestamp + 1 days);

        // Simulate rollup upgrade: register the active attester on rollup B
        // (mimics GSE _moveWithLatestRollup=true migrating the active attester)
        aztec.mint(address(rollupB), ACTIVATION_THRESHOLD);
        rollupB.setStake(activeAttester, ACTIVATION_THRESHOLD, address(stakingManager));
        rollupRegistry.setCanonicalRollup(address(rollupB));

        // Refresh both attesters
        stakingManager.refreshAttesterState(_attesterAddresses(2));

        // Active attester should still be tracked as active (visible on rollup B)
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "active attester should remain active");
        // Exiting attester should still be pending (exit on rollup A not yet exitable)
        assertTrue(stakingManager.isUnstakePending(exitingAttester), "exiting attester should still be pending");

        // Advance time and finalize the exit on rollup A
        vm.warp(block.timestamp + 2 days);
        stakingManager.refreshAttesterState(_attesterAddresses(2));

        assertFalse(stakingManager.isUnstakePending(exitingAttester), "exiting attester should be finalized");
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "active attester unaffected");

        // Claim funds
        uint256 coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();

        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exitAmount should match finalized exit");
        assertEq(received, ACTIVATION_THRESHOLD, "received should match tokens from old rollup");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD, "core should get the funds");
    }

    /// @notice Regression test for the phantom credit bug: without the exitRollup fix, an Exiting
    ///         attester queried against the new rollup (which has no exit record) would be
    ///         interpreted as "externally finalized", crediting _pendingClaimAmount without
    ///         any actual token transfer.
    function test_RefreshAttesterState_NoPhantomCredit_AfterUpgrade() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;

        // Unstake on rollup A
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Make exit not yet exitable
        rollup.setExitReady(attester, block.timestamp + 1 days);

        // Upgrade to rollup B
        rollupRegistry.setCanonicalRollup(address(rollupB));

        // Refresh multiple times -- should never produce phantom credits
        for (uint256 i; i < 3; ++i) {
            stakingManager.refreshAttesterState(_attesterAddresses(1));

            vm.prank(core);
            (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();

            assertEq(exitAmount, 0, "exitAmount must be 0 on each refresh -- no phantom credit");
            assertEq(received, 0, "received must be 0 -- no funds have been transferred");
        }

        // Attester must still be tracked as exiting
        assertTrue(stakingManager.isUnstakePending(attester), "attester should remain exiting");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "exiting count should be 1");
    }

    /// @notice Multiple attesters exiting on rollup A: after upgrade, all should finalize correctly
    ///         on the old rollup once their exits become exitable.
    function test_RefreshAttesterState_MultipleExitingAttesters_AllFinalizeOnOldRollup() external {
        uint256 count = 3;
        _setupMultipleActiveAttesters(count);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);

        // Unstake all
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * count);
        assertEq(stakingManager.getPendingUnstakeCount(), count, "all should be exiting");

        // Stagger exit times
        for (uint256 i; i < count; ++i) {
            rollup.setExitReady(keys[i].attester, block.timestamp + (i + 1) * 1 days);
        }

        // Upgrade to rollup B
        rollupRegistry.setCanonicalRollup(address(rollupB));

        // Advance past all exit times
        vm.warp(block.timestamp + (count + 1) * 1 days);

        // Refresh all
        stakingManager.refreshAttesterState(_attesterAddresses(count));

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "all exits should be finalized");

        // Claim
        uint256 coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();

        uint256 expectedTotal = ACTIVATION_THRESHOLD * count;
        assertEq(exitAmount, expectedTotal, "exitAmount should match all finalized exits");
        assertEq(received, expectedTotal, "received should match total tokens from old rollup");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + expectedTotal, "core should receive all funds");
    }

    /*//////////////////////////////////////////////////////////////
                ROLLUP UPGRADE -- QUEUED ATTESTER
    //////////////////////////////////////////////////////////////*/

    /// @notice A Queued attester that was deposited on rollup A becomes effectively orphaned
    ///         when the registry upgrades to rollup B (where the attester is NONE).
    ///         refreshAttesterState should leave the attester as Queued (not crash or remove it).
    ///         purgeFailedQueueEntry would be needed to clean it up.
    function test_RefreshAttesterState_QueuedAttester_SurvivesRollupUpgrade() external {
        // Stake 1 attester on rollup A (Queued)
        _setupStakedAttester();
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "pre: queued");

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        // Deploy new rollup, update registry to point to it
        rollupRegistry.setCanonicalRollup(address(rollupB));

        // On the new rollup, getAttesterView returns NONE (attester doesn't exist there)
        // refreshAttesterState: attester is Queued, rollup shows NONE -> stays Queued
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // Attester remains Queued, counts unchanged
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "still queued after rollup upgrade");
        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, stateBefore.stakedAmount, "stakedAmount unchanged");
    }

    /*//////////////////////////////////////////////////////////////
            ROLLUP UPGRADE -- EXTERNAL EXIT ON OLD ROLLUP
    //////////////////////////////////////////////////////////////*/

    /// @notice An externally initiated exit detected during refresh on rollup A should store
    ///         the correct exitRollup, so it survives a subsequent upgrade.
    function test_RefreshAttesterState_ExternalExitOnOldRollup_SurvivesUpgrade() external {
        _setupActiveAttester();
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        address attester = keys[0].attester;

        // External party initiates exit on rollup A (zombie exit with future exitable time)
        rollup.setExternalExit(attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        // First refresh: detects the external exit, transitions Active -> Exiting, stores exitRollup = rollup A
        stakingManager.refreshAttesterState(_attesterAddresses(1));
        assertTrue(stakingManager.isUnstakePending(attester), "should detect external exit");

        // Upgrade to rollup B
        rollupRegistry.setCanonicalRollup(address(rollupB));

        // Refresh after upgrade -- should still see the exit on rollup A
        stakingManager.refreshAttesterState(_attesterAddresses(1));
        assertTrue(stakingManager.isUnstakePending(attester), "should still be exiting after upgrade");

        // No phantom credits
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(exitAmount, 0, "no phantom credit");
        assertEq(received, 0, "no funds transferred");

        // Advance time and finalize
        vm.warp(block.timestamp + 2 days);
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertFalse(stakingManager.isUnstakePending(attester), "exit should be finalized");

        uint256 coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        (received, exitAmount) = stakingManager.getUnstakedFunds();

        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exitAmount should match finalized amount");
        assertEq(received, ACTIVATION_THRESHOLD, "received should match transferred tokens");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD, "core gets the funds");
    }

    /*//////////////////////////////////////////////////////////////
                    ROLLUP UPGRADE -- LEGACY REWARDS
    //////////////////////////////////////////////////////////////*/

    function test_GetClaimableRewards_IncludesStoredLegacyRollupAfterCanonicalChanges() external {
        uint256 legacyRewards = 7 ether;
        _setRollupRewards(rollup, legacyRewards);
        rollupRegistry.setCanonicalRollup(address(rollupB));

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, legacyRewards, "legacy rollup rewards should remain claimable");
    }

    function test_GetClaimableRewards_IncludesNewCanonicalBeforePersisted() external {
        uint256 canonicalRewards = 11 ether;
        rollupRegistry.setCanonicalRollup(address(rollupB));
        _setRollupRewards(rollupB, canonicalRewards);

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, canonicalRewards, "new canonical rewards should be read before sync");
    }

    function test_GetClaimableRewards_SumsLegacyAndCanonicalRewards() external {
        uint256 legacyRewards = 7 ether;
        uint256 canonicalRewards = 11 ether;
        _setRollupRewards(rollup, legacyRewards);
        rollupRegistry.setCanonicalRollup(address(rollupB));
        _setRollupRewards(rollupB, canonicalRewards);

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, legacyRewards + canonicalRewards, "legacy plus canonical rewards should be summed");
    }

    function test_GetClaimableRewards_SkipsRevertingLegacyRollup() external {
        uint256 canonicalRewards = 11 ether;
        _setRollupRewards(rollup, 7 ether);
        rollup.setGetRewardsShouldFail(address(rewardsAccumulator), true);
        rollupRegistry.setCanonicalRollup(address(rollupB));
        _setRollupRewards(rollupB, canonicalRewards);

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, canonicalRewards, "reverting legacy rollup should be skipped");
    }

    function test_HarvestRewards_ClaimsFromLegacyAndCanonicalRollups() external {
        uint256 legacyRewards = 7 ether;
        uint256 canonicalRewards = 11 ether;
        _setRollupRewards(rollup, legacyRewards);
        rollupRegistry.setCanonicalRollup(address(rollupB));
        _setRollupRewards(rollupB, canonicalRewards);

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, legacyRewards + canonicalRewards, "should harvest all tracked rollup rewards");
        assertEq(rollup.getSequencerRewards(address(rewardsAccumulator)), 0, "legacy rewards drained");
        assertEq(rollupB.getSequencerRewards(address(rewardsAccumulator)), 0, "canonical rewards drained");
    }

    function test_HarvestRewards_TracksNewCanonicalRollupInStorage() external {
        uint256 firstCanonicalRewards = 11 ether;
        uint256 secondCanonicalRewards = 13 ether;
        rollupRegistry.setCanonicalRollup(address(rollupB));
        _setRollupRewards(rollupB, firstCanonicalRewards);

        vm.prank(core);
        stakingManager.harvestRewards();

        rollupRegistry.setCanonicalRollup(address(rollupC));
        _setRollupRewards(rollupB, secondCanonicalRewards);

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, secondCanonicalRewards, "previous canonical should stay tracked after harvest sync");
    }

    function test_HarvestRewards_RemovesLegacyRollupAfterSuccessfulClaim() external {
        uint256 legacyRewards = 7 ether;
        _setRollupRewards(rollup, legacyRewards);
        rollupRegistry.setCanonicalRollup(address(rollupB));

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, legacyRewards, "legacy rewards should be harvested");

        _setRollupRewards(rollup, 5 ether);
        rollupRegistry.setCanonicalRollup(address(rollupC));

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, 0, "successfully claimed legacy rollup should have been pruned");
    }

    function test_HarvestRewards_KeepsLegacyRollupWhenClaimFails() external {
        uint256 legacyRewards = 7 ether;
        _setRollupRewards(rollup, legacyRewards);
        rollup.setClaimShouldFail(address(rewardsAccumulator), true);
        rollupRegistry.setCanonicalRollup(address(rollupB));

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, 0, "failed claim should not harvest");

        rollupRegistry.setCanonicalRollup(address(rollupC));
        rollup.setClaimShouldFail(address(rewardsAccumulator), false);

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, legacyRewards, "failed legacy claim should remain tracked");
    }

    function test_RemoveDrainedRewardRollup_RemovesLegacyRollupWithZeroRewards() external {
        rollupRegistry.setCanonicalRollup(address(rollupB));

        vm.prank(defaultAdmin);
        stakingManager.removeDrainedRewardRollup(address(rollup));

        _setRollupRewards(rollup, 5 ether);
        rollupRegistry.setCanonicalRollup(address(rollupC));

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, 0, "governance-removed legacy rollup should not be tracked");
    }

    function test_RevertWhen_RemoveDrainedRewardRollup_HasPendingRewards() external {
        uint256 legacyRewards = 7 ether;
        _setRollupRewards(rollup, legacyRewards);
        rollupRegistry.setCanonicalRollup(address(rollupB));

        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingManager.StakingManager__RewardRollupHasPendingRewards.selector, address(rollup), legacyRewards
            )
        );
        vm.prank(defaultAdmin);
        stakingManager.removeDrainedRewardRollup(address(rollup));
    }

    function test_RevertWhen_RemoveDrainedRewardRollup_CanonicalRollup() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingManager.StakingManager__CannotRemoveCanonicalRewardRollup.selector, address(rollup)
            )
        );
        vm.prank(defaultAdmin);
        stakingManager.removeDrainedRewardRollup(address(rollup));
    }

    function test_RevertWhen_RemoveDrainedRewardRollup_NotTracked() external {
        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__RewardRollupNotTracked.selector, address(rollupB))
        );
        vm.prank(defaultAdmin);
        stakingManager.removeDrainedRewardRollup(address(rollupB));
    }

    function test_RevertWhen_RemoveDrainedRewardRollup_NonAdmin() external {
        rollupRegistry.setCanonicalRollup(address(rollupB));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, stakingManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        stakingManager.removeDrainedRewardRollup(address(rollup));
    }

    function test_RemoveDrainedRewardRollup_KeepsRollupWhenRewardQueryFails() external {
        rollupRegistry.setCanonicalRollup(address(rollupB));
        rollup.setGetRewardsShouldFail(address(rewardsAccumulator), true);

        vm.expectRevert();
        vm.prank(defaultAdmin);
        stakingManager.removeDrainedRewardRollup(address(rollup));

        rollup.setGetRewardsShouldFail(address(rewardsAccumulator), false);
        _setRollupRewards(rollup, 5 ether);
        rollupRegistry.setCanonicalRollup(address(rollupC));

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, 5 ether, "failed cleanup read should leave legacy rollup tracked");
    }

    function test_HarvestRewards_NeverRemovesCurrentCanonicalRollupWhenZeroRewards() external {
        rollupRegistry.setCanonicalRollup(address(rollupB));

        vm.prank(core);
        stakingManager.harvestRewards();

        rollupRegistry.setCanonicalRollup(address(rollupC));
        _setRollupRewards(rollupB, 11 ether);

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, 11 ether, "zero-reward canonical should remain tracked after later upgrade");
    }
}
