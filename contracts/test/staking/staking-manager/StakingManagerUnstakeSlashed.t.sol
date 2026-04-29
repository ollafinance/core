// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";
import { IAztecRollup } from "src/staking/interfaces/IAztecRollup.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

/// @title StakingManagerUnstakeSlashedTest
/// @notice Regression tests for phantom stakedAmount inflation when unstaking
///         an attester that was slashed on the rollup without a prior refreshAttesterState.
contract StakingManagerUnstakeSlashedTest is StakingManagerBaseTest {
    /// @notice The rollup's `stakes` mapping lives at storage slot 1 in MockAztecRollup.
    uint256 private constant ROLLUP_STAKES_SLOT = 1;

    /// @dev Overwrites the rollup-side stake for `attester` without touching StakingManager cache.
    function _slashOnRollup(address attester, uint256 newStake) internal {
        bytes32 slot = keccak256(abi.encode(attester, ROLLUP_STAKES_SLOT));
        vm.store(address(rollup), slot, bytes32(newStake));
    }

    /*//////////////////////////////////////////////////////////////
                       CORE REGRESSION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Unstaking a slashed attester must not leave a phantom in stakedAmount.
    function test_Unstake_SlashedAttester_NoPhantomInStakedAmount() external {
        _setupActiveAttester();
        address attester = address(uint160(1));

        // Slash on rollup: 100 ether → 80 ether (no refresh called)
        uint256 slashedBalance = 80 ether;
        _slashOnRollup(attester, slashedBalance);

        // Unstake without prior refresh
        vm.prank(core);
        uint256 unstaked = stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();

        // exitAmount = effectiveBalance = 80 ether (what the rollup actually holds)
        assertEq(unstaked, slashedBalance, "unstaked should equal the slashed effective balance");
        // stakedAmount must be 0 — not 20 ether phantom
        assertEq(state.stakedAmount, 0, "stakedAmount must be zero, no phantom from slashing gap");
        assertEq(state.pendingUnstakeAmount, slashedBalance, "pendingUnstake should equal exit amount");
        // totalStaked = stakedAmount + pendingUnstakeAmount = 0 + 80 = 80
        assertEq(stakingManager.totalStaked(), slashedBalance, "totalStaked must reflect only real assets");
    }

    /// @notice The slashing gap must be recorded in slashingDelta.
    function test_Unstake_SlashedAttester_SlashingDeltaRecorded() external {
        _setupActiveAttester();
        address attester = address(uint160(1));

        uint256 slashedBalance = 75 ether;
        _slashOnRollup(attester, slashedBalance);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        uint256 expectedSlashingLoss = ACTIVATION_THRESHOLD - slashedBalance; // 25 ether
        assertEq(state.slashingDelta, expectedSlashingLoss, "slashingDelta must capture the slashing gap");
    }

    /// @notice Fully slashed attesters make the real rollup revert instead of returning false.
    function test_Unstake_FullySlashedAttester_InitiateWithdrawRevert_RemovesAttester() external {
        _setupActiveAttester();
        address attester = address(uint160(1));
        _slashOnRollup(attester, 0);
        bytes memory revertReason = "AZTEC_FULLY_SLASHED";

        vm.mockCallRevert(
            address(rollup),
            abi.encodeWithSelector(IAztecRollup.initiateWithdraw.selector, attester, address(stakingManager)),
            revertReason
        );

        vm.expectEmit(true, true, false, true, address(stakingManager));
        emit FullySlashedAttesterPurged(attester, ACTIVATION_THRESHOLD, revertReason);

        vm.prank(core);
        uint256 unstaked = stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(unstaked, 0, "fully slashed attester has no recoverable unstake");
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "fully slashed attester should leave active set");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no exit should be tracked for a full slash");
        assertEq(state.stakedAmount, 0, "cached stake should be removed");
        assertEq(state.pendingUnstakeAmount, 0, "no pending unstake should be added");
        assertEq(state.slashingDelta, ACTIVATION_THRESHOLD, "full stake should be recorded as slashed");
    }

    /// @notice Nonzero-balance rollup reverts are not treated as fully slashed local purges.
    function test_Unstake_SlashedAttester_InitiateWithdrawRevert_NonzeroBalanceReverts() external {
        _setupActiveAttester();
        address attester = address(uint160(1));
        _slashOnRollup(attester, 1 wei);

        vm.mockCallRevert(
            address(rollup),
            abi.encodeWithSelector(IAztecRollup.initiateWithdraw.selector, attester, address(stakingManager)),
            "AZTEC_UNAVAILABLE"
        );

        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnstakeFailed.selector, attester));
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
    }

    /// @notice Multiple attesters, one slashed — only the slashed one should produce a delta.
    function test_Unstake_OneSlashedAmongMultiple_CorrectAccounting() external {
        _setupMultipleActiveAttesters(3);
        address attester1 = address(uint160(1));

        // Slash only attester1: 100 → 60
        uint256 slashedBalance = 60 ether;
        _slashOnRollup(attester1, slashedBalance);

        // Unstake all 3
        vm.prank(core);
        uint256 unstaked = stakingManager.unstake(ACTIVATION_THRESHOLD * 3);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        // 2 healthy (100 each) + 1 slashed (60) = 260 actually unstaked
        uint256 expectedUnstaked = ACTIVATION_THRESHOLD * 2 + slashedBalance;
        assertEq(unstaked, expectedUnstaked, "total unstaked should sum healthy + slashed balances");
        assertEq(state.stakedAmount, 0, "stakedAmount must be zero after full unstake");
        assertEq(state.pendingUnstakeAmount, expectedUnstaked, "pendingUnstake should match total exit amounts");
        assertEq(
            state.slashingDelta,
            ACTIVATION_THRESHOLD - slashedBalance,
            "slashingDelta should reflect only the slashed attester's loss"
        );
    }

    /// @notice After unstaking a slashed attester, refreshAttesterState must not re-inflate stakedAmount.
    function test_Unstake_SlashedAttester_RefreshAfterDoesNotReInflate() external {
        _setupActiveAttester();
        address attester = address(uint160(1));

        _slashOnRollup(attester, 80 ether);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory stateAfterUnstake = stakingManager.getStakingState();
        assertEq(stateAfterUnstake.stakedAmount, 0, "pre-condition: stakedAmount is 0 after unstake");

        // Refresh the now-Exiting attester — must not add to stakedAmount
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfterRefresh = stakingManager.getStakingState();
        assertEq(stateAfterRefresh.stakedAmount, 0, "stakedAmount must remain 0 after refresh of exiting attester");
    }

    /// @notice Full lifecycle: slash → unstake → refresh → finalize → claim.
    ///         Verifies no phantom leaks through the entire exit pipeline.
    function test_Unstake_SlashedAttester_FullLifecycle() external {
        _setupActiveAttester();
        address attester = address(uint160(1));
        uint256 slashedBalance = 70 ether;

        _slashOnRollup(attester, slashedBalance);

        // 1. Unstake
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // 2. Refresh to finalize (mock exit is immediately exitable)
        address[] memory attesters = _attesterAddresses(1);
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, 0, "stakedAmount should be 0");
        assertEq(state.pendingUnstakeAmount, 0, "pendingUnstake should be 0 after finalization");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no exiting attesters remain");

        // 3. Claim funds
        vm.prank(core);
        (uint256 received, uint256 exitAmount) = stakingManager.getUnstakedFunds();
        assertEq(received, slashedBalance, "received should equal the actual slashed balance");
        assertEq(exitAmount, slashedBalance, "exitAmount should equal the slashed balance");

        // 4. totalStaked should be 0 — nothing staked, nothing pending
        assertEq(stakingManager.totalStaked(), 0, "totalStaked must be 0 at end of lifecycle");
    }

    /// @notice Fuzz: any slashing percentage should produce correct accounting.
    function testFuzz_Unstake_SlashedAttester(uint256 slashedBalance) external {
        slashedBalance = bound(slashedBalance, 0, ACTIVATION_THRESHOLD);

        _setupActiveAttester();
        address attester = address(uint160(1));
        _slashOnRollup(attester, slashedBalance);

        vm.prank(core);
        uint256 unstaked = stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(unstaked, slashedBalance, "unstaked should equal slashed balance");
        assertEq(state.stakedAmount, 0, "stakedAmount must be zero");
        assertEq(state.pendingUnstakeAmount, slashedBalance, "pendingUnstake should equal exit amount");

        if (ACTIVATION_THRESHOLD > slashedBalance) {
            assertEq(
                state.slashingDelta,
                ACTIVATION_THRESHOLD - slashedBalance,
                "slashingDelta should equal the slashing gap"
            );
        } else {
            assertEq(state.slashingDelta, 0, "no slashingDelta when not slashed");
        }
    }
}
