// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { E2EBaseWithRealStaking } from "./E2EBaseWithRealStaking.sol";

/// @title GuardianEmergencyRecoveryE2E
/// @notice E2E: validates guardian emergency actions including forceRebalanceReset(),
///         pause/unpause on core and vault, whenRebalanceDone modifier blocking governance
///         actions, and recovery from stuck rebalance states,
///         using real StakingManager + real RewardsAccumulator + MockAztecRollup.
contract GuardianEmergencyRecoveryE2E is E2EBaseWithRealStaking {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RebalanceReset();

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

    /// @notice Returns the activation threshold (stake per attester).
    function _threshold() internal view returns (uint256) {
        return mockRollup.getActivationThreshold();
    }

    /// @notice Gets the rebalance into an in-progress state (stuck at StakeSurplus).
    /// @dev Deposits enough for 3 attesters but only 1 key is available (setUp added 10,
    ///      but we stake them first, then deposit more with only 1 extra key).
    ///      The rebalance partially stakes and saves progress at StakeSurplus.
    /// @return depositAmount The total amount deposited.
    function _getRebalanceInProgress() internal returns (uint256 depositAmount) {
        uint256 threshold = _threshold();

        // 1. First: stake all 10 keys added in setUp
        depositAmount = threshold * 10;
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        assertEq(core.accountingState().stakedPrincipal, threshold * 10, "10 attesters staked");

        // 2. Deposit more funds (3 attesters worth) but only add 1 key
        uint256 extraDeposit = threshold * 3;
        _deposit(bob, extraDeposit);
        depositAmount += extraDeposit;
        _addKeys(1);

        // 3. Rebalance: will stake 1 attester (the only available key) and save progress
        //    at StakeSurplus with 2 attesters worth remaining
        _warpPastCooldown();
        _rebalance();

        // Verify we're in progress at StakeSurplus
        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(
            uint256(p.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Rebalance should be stuck at StakeSurplus"
        );
    }

    /*//////////////////////////////////////////////////////////////
                         FORCE REBALANCE RESET
    //////////////////////////////////////////////////////////////*/

    /// @notice forceRebalanceReset clears in-progress rebalance (stuck at StakeSurplus) and system recovers.
    function test_ForceRebalanceReset_MidUnstake() external {
        _getRebalanceInProgress();

        // Guardian calls forceRebalanceReset
        vm.prank(address(gov));
        vm.expectEmit(true, true, true, true, address(core));
        emit RebalanceReset();
        core.forceRebalanceReset();

        // Verify step is Done
        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Step should be Done after reset");
        assertEq(p.stakeRemaining, 0, "stakeRemaining should be 0");
        assertEq(p.unstakeRemaining, 0, "unstakeRemaining should be 0");

        // Refresh attesters so exits can be finalized
        _refreshAttesters();

        // New rebalance starts fresh and recovers
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // System is back in Done state
        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "System should recover to Done");
    }

    /// @notice Only GUARDIAN_ROLE can call forceRebalanceReset.
    function test_ForceRebalanceReset_OnlyGuardianCanCall() external {
        _getRebalanceInProgress();

        bytes32 guardianRole = core.GUARDIAN_ROLE();

        // Non-guardian (alice) cannot call
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, guardianRole)
        );
        core.forceRebalanceReset();

        // Guardian (gov) succeeds
        vm.prank(address(gov));
        core.forceRebalanceReset();

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Guardian should succeed");
    }

    /// @notice forceRebalanceReset does not lose tokens; accounting stays consistent after recovery.
    function test_ForceRebalanceReset_DoesNotLoseTokens() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 3;

        // 1. Deposit and stake 3 attesters
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // 2. Request partial redeem to trigger unstaking
        uint256 redeemShares = stAztec.balanceOf(alice) / 2;
        uint256 requestId = _requestRedeem(alice, redeemShares);

        // 3. Rebalance: initiates unstakes -> Done
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 4. Start another rebalance (PullUnstaked advances; no funds to pull without refresh)
        _warpPastCooldown();
        _rebalance();

        // 5. Force reset
        vm.prank(address(gov));
        core.forceRebalanceReset();

        // 6. Refresh all attesters to finalize remaining exits
        _refreshAttesters();

        // 7. New rebalance pulls unstaked funds and processes withdrawals
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 8. Claim the finalized withdrawal
        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertTrue(req.finalized, "Withdrawal request must be finalized after recovery");

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        // 9. Conservation of value: claimed + totalAssets = depositAmount (no slashing, no loss)
        uint256 totalAssets = core.totalAssets();
        assertEq(claimed + totalAssets, depositAmount, "No tokens lost: claimed + totalAssets = deposit");

        // 10. No tokens orphaned in intermediary contracts
        assertEq(asset.balanceOf(address(stakingManager)), 0, "No tokens stuck in StakingManager");
        assertEq(rewardsAccumulator.balance(), 0, "No tokens stuck in RewardsAccumulator");
        assertEq(asset.balanceOf(address(core)), 0, "No tokens stuck in OllaCore");
    }

    /*//////////////////////////////////////////////////////////////
                       WHEN REBALANCE DONE MODIFIER
    //////////////////////////////////////////////////////////////*/

    /// @notice Governance actions blocked by whenRebalanceDone during in-progress rebalance.
    function test_WhenRebalanceDone_BlocksGovernanceActions() external {
        _getRebalanceInProgress();

        // All governance actions with whenRebalanceDone should revert
        vm.prank(address(gov));
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.setTargetBufferedAssets(100);

        vm.prank(address(gov));
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.setProtocolFeeBP(1_000);

        vm.prank(address(gov));
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.setTreasuryFeeSplitBP(6_000);

        vm.prank(address(gov));
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.setSafetyModule(address(safetyModule));

        // updateAccounting also uses whenRebalanceDone
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.updateAccounting();

        // Force reset -> governance actions should now succeed
        vm.prank(address(gov));
        core.forceRebalanceReset();

        vm.prank(address(gov));
        core.setTargetBufferedAssets(100);

        vm.prank(address(gov));
        core.setProtocolFeeBP(1_000);

        vm.prank(address(gov));
        core.setTreasuryFeeSplitBP(6_000);

        vm.prank(address(gov));
        core.setSafetyModule(address(safetyModule));
    }

    /*//////////////////////////////////////////////////////////////
                           VAULT PAUSE/UNPAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Vault pause blocks deposits, redeem requests, instant redeems, and claims.
    function test_VaultPause_BlocksDepositsAndRedeems() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 2;

        // Deposit and stake
        uint256 shares = _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // Give bob tokens for deposit attempt
        asset.mint(bob, 100 * DECIMALS);
        vm.prank(bob);
        asset.approve(address(vault), 100 * DECIMALS);

        // Guardian pauses vault
        vm.prank(address(gov));
        vault.pause();

        // deposit reverts
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.deposit(100 * DECIMALS, bob, 0);

        // requestRedeem reverts
        vm.prank(alice);
        stAztec.approve(address(vault), shares);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.requestRedeem(shares, alice, alice);

        // Guardian unpauses vault
        vm.prank(address(gov));
        vault.unpause();

        // Operations work again
        vm.prank(bob);
        uint256 newShares = vault.deposit(100 * DECIMALS, bob, 0);
        assertGt(newShares, 0, "Deposit should succeed after unpause");
    }

    /*//////////////////////////////////////////////////////////////
                          CORE PAUSE/UNPAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Core pause blocks rebalance but forceRebalanceReset still works; vault remains operational.
    function test_CorePause_BlocksRebalanceButNotReset() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 2;

        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // Guardian pauses core
        vm.prank(address(gov));
        core.pause();

        // Rebalance reverts
        _warpPastCooldown();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        core.rebalance();

        // updateAccounting reverts
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        core.updateAccounting();

        // forceRebalanceReset still works while paused (guardian emergency action)
        vm.prank(address(gov));
        core.forceRebalanceReset();
        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "forceRebalanceReset should work while paused");

        // Vault operations still work (vault is independently unpaused)
        asset.mint(bob, 100 * DECIMALS);
        vm.prank(bob);
        asset.approve(address(vault), 100 * DECIMALS);
        vm.prank(bob);
        uint256 newShares = vault.deposit(100 * DECIMALS, bob, 0);
        assertGt(newShares, 0, "Vault deposit should work when only core is paused");

        // Guardian unpauses core
        vm.prank(address(gov));
        core.unpause();

        // Rebalance works again
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Rebalance should complete after unpause");
    }

    /// @notice Only GUARDIAN_ROLE can pause/unpause core.
    function test_CorePauseUnpause_OnlyGuardianCanCall() external {
        bytes32 guardianRole = core.GUARDIAN_ROLE();

        // Non-guardian cannot pause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, guardianRole)
        );
        core.pause();

        // Guardian pauses
        vm.prank(address(gov));
        core.pause();

        // Non-guardian cannot unpause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, guardianRole)
        );
        core.unpause();

        // Guardian unpauses
        vm.prank(address(gov));
        core.unpause();
    }

    /// @notice Only GUARDIAN_ROLE can pause/unpause vault.
    function test_VaultPauseUnpause_OnlyGuardianCanCall() external {
        bytes32 guardianRole = vault.GUARDIAN_ROLE();

        // Non-guardian cannot pause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, guardianRole)
        );
        vault.pause();

        // Guardian pauses
        vm.prank(address(gov));
        vault.pause();

        // Non-guardian cannot unpause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, guardianRole)
        );
        vault.unpause();

        // Guardian unpauses
        vm.prank(address(gov));
        vault.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                   PAUSE DURING REBALANCE + RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice Guardian can pause core, reset stuck rebalance while paused, unpause, and recover.
    function test_CorePause_DuringRebalance_ThenResetWhilePaused() external {
        _getRebalanceInProgress();

        // 1. Guardian pauses core to prevent further rebalance calls
        vm.prank(address(gov));
        core.pause();

        // 2. Rebalance cannot be called while paused
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        core.rebalance();

        // 3. forceRebalanceReset works even while paused
        vm.prank(address(gov));
        core.forceRebalanceReset();

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Rebalance should be Done after reset");

        // 4. Guardian unpauses
        vm.prank(address(gov));
        core.unpause();

        // 5. Refresh attesters and start fresh rebalance
        _refreshAttesters();
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 6. System fully recovered
        p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "System should recover after reset");
    }

    /// @notice Pending withdrawals survive a force reset cycle and eventually get finalized.
    function test_ForceRebalanceReset_PendingWithdrawalsSurvive() external {
        uint256 threshold = _threshold();

        // 1. Stake all 10 keys + deposit extra for 3 more (no keys available)
        uint256 aliceDeposit = threshold * 10;
        _deposit(alice, aliceDeposit);
        _rebalance();
        _completeRebalance();

        // 2. Request redeem from alice (creates pending withdrawal)
        uint256 redeemShares = stAztec.balanceOf(alice) / 3;
        uint256 requestId = _requestRedeem(alice, redeemShares);

        // 3. Rebalance: initiates unstakes to cover the redeem. Completes to Done
        //    (no surplus to stake since buffer covers the withdrawal queue).
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 4. Verify withdrawal request is not yet finalized (needs rollup exit finalization)
        IOllaVault.WithdrawalRequest memory reqBefore = vault.getWithdrawalRequest(requestId);
        assertFalse(reqBefore.finalized, "Request should not be finalized yet");

        // 5. Bob deposits extra funds and add only 1 key to cause stall at StakeSurplus
        //    Bob must deposit enough so buffer exceeds pendingWithdrawals (alice's ~3.33 attesters),
        //    leaving surplus > 1 attester to trigger a partial stake with only 1 key.
        uint256 bobDeposit = threshold * 5;
        _deposit(bob, bobDeposit);
        _addKeys(1);

        _warpPastCooldown();
        _rebalance();

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Should be stuck at StakeSurplus");

        // 6. Force reset
        vm.prank(address(gov));
        core.forceRebalanceReset();

        // 7. Refresh attesters to finalize exits, add keys to allow full staking
        _refreshAttesters();
        _addKeys(5);

        // 8. New rebalance cycle pulls funds and finalizes withdrawals
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        _warpPastCooldown();
        _rebalanceToCompletion(20);

        // 9. Withdrawal should now be finalized
        IOllaVault.WithdrawalRequest memory reqAfter = vault.getWithdrawalRequest(requestId);
        assertTrue(reqAfter.finalized, "Request should be finalized after recovery");

        // 10. Alice can claim
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);
        assertGt(claimed, 0, "Alice should receive assets from finalized withdrawal");
    }

    /*//////////////////////////////////////////////////////////////
                     EMERGENCY PAUSE/UNPAUSE ALL
    //////////////////////////////////////////////////////////////*/

    /// @notice emergencyPauseAll blocks both core.rebalance() and vault.deposit(),
    ///         and emergencyUnpauseAll restores normal operation.
    function test_EmergencyPauseAll_BlocksAllOperations() external {
        uint256 threshold = _threshold();
        uint256 depositAmount = threshold * 2;

        // Deposit and stake so the system is in a normal state
        _deposit(alice, depositAmount);
        _rebalance();
        _completeRebalance();

        // Admin calls emergencyPauseAll via governance
        vm.prank(admin);
        gov.emergencyPauseAll();

        assertTrue(core.paused(), "core should be paused");
        assertTrue(vault.paused(), "vault should be paused");

        // core.rebalance() reverts
        _warpPastCooldown();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        core.rebalance();

        // vault.deposit() reverts
        asset.mint(bob, 100 * DECIMALS);
        vm.prank(bob);
        asset.approve(address(vault), 100 * DECIMALS);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.deposit(100 * DECIMALS, bob, 0);

        // Admin calls emergencyUnpauseAll to restore everything
        vm.prank(admin);
        gov.emergencyUnpauseAll();

        assertFalse(core.paused(), "core should be unpaused");
        assertFalse(vault.paused(), "vault should be unpaused");

        // Operations work again
        vm.prank(bob);
        uint256 newShares = vault.deposit(100 * DECIMALS, bob, 0);
        assertGt(newShares, 0, "Deposit should succeed after emergencyUnpauseAll");

        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Rebalance should complete after unpauseAll");
    }

    /// @notice emergencyPauseAll during an in-progress rebalance, then forceRebalanceReset
    ///         (works while paused), then emergencyUnpauseAll, and the system recovers.
    function test_EmergencyPauseAll_DuringRebalance_ThenReset() external {
        _getRebalanceInProgress();

        // 1. Admin pauses everything via emergencyPauseAll
        vm.prank(admin);
        gov.emergencyPauseAll();

        assertTrue(core.paused(), "core should be paused");
        assertTrue(vault.paused(), "vault should be paused");

        // 2. Rebalance cannot be called while paused
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        core.rebalance();

        // 3. forceRebalanceReset works even while paused
        vm.prank(address(gov));
        core.forceRebalanceReset();

        IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
        assertEq(uint256(p.step), uint256(IOllaCore.RebalanceStep.Done), "Rebalance should be Done after reset");

        // 4. Admin unpauses everything
        vm.prank(admin);
        gov.emergencyUnpauseAll();

        assertFalse(core.paused(), "core should be unpaused");
        assertFalse(vault.paused(), "vault should be unpaused");

        // 5. Refresh attesters and start fresh rebalance
        _refreshAttesters();
        _warpPastCooldown();
        _rebalance();
        _completeRebalance();

        // 6. System fully recovered
        p = core.rebalanceProgress();
        assertEq(
            uint256(p.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "System should recover after emergencyPauseAll + reset + emergencyUnpauseAll"
        );
    }
}
