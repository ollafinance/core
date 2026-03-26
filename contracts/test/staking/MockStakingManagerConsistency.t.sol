// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";

/// @title MockStakingManagerConsistencyTest
/// @notice Verifies that MockStakingManager maintains internal state consistency
///         between stake()/unstake() mutations and totalStaked()/getStakingState() reads.
contract MockStakingManagerConsistencyTest is Test {
    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockStakingManager internal sm;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        sm = new MockStakingManager();
    }

    /*//////////////////////////////////////////////////////////////
                      STAKE / TOTAL CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice stake() increases totalStaked and getStakingState().stakedAmount.
    function test_MockSM_StakeTotalStakedConsistency() public {
        sm.stake(100e18);

        assertEq(sm.totalStaked(), 100e18, "totalStaked should equal staked amount");

        IStakingManager.StakingState memory state = sm.getStakingState();
        assertEq(state.stakedAmount, 100e18, "getStakingState().stakedAmount should match totalStaked");
    }

    /// @notice Multiple stakes accumulate correctly.
    function test_MockSM_MultipleStakes_Accumulate() public {
        sm.stake(50e18);
        sm.stake(30e18);
        sm.stake(20e18);

        assertEq(sm.totalStaked(), 100e18, "totalStaked should accumulate all stakes");

        IStakingManager.StakingState memory state = sm.getStakingState();
        assertEq(state.stakedAmount, 100e18, "getStakingState should match totalStaked");
    }

    /*//////////////////////////////////////////////////////////////
                     UNSTAKE / TOTAL CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice unstake() decreases totalStaked and getStakingState().stakedAmount.
    function test_MockSM_UnstakeReducesTotalStaked() public {
        sm.stake(100e18);
        sm.unstake(40e18);

        assertEq(sm.totalStaked(), 60e18, "totalStaked should decrease by unstaked amount");

        IStakingManager.StakingState memory state = sm.getStakingState();
        assertEq(state.stakedAmount, 60e18, "getStakingState().stakedAmount should match totalStaked");
    }

    /// @notice unstake() is capped at the available staked amount.
    function test_MockSM_UnstakeCappedAtStaked() public {
        sm.stake(50e18);
        uint256 unstaked = sm.unstake(80e18);

        assertEq(unstaked, 50e18, "unstake should be capped at staked amount");
        assertEq(sm.totalStaked(), 0, "totalStaked should be zero after full unstake");

        IStakingManager.StakingState memory state = sm.getStakingState();
        assertEq(state.stakedAmount, 0, "getStakingState().stakedAmount should be zero");
    }

    /*//////////////////////////////////////////////////////////////
              STAKING STATE REFLECTS STAKE / UNSTAKE
    //////////////////////////////////////////////////////////////*/

    /// @notice getStakingState reflects stake and unstake operations.
    function test_MockSM_GetStakingState_ReflectsStakeUnstake() public {
        sm.stake(200e18);

        IStakingManager.StakingState memory stateAfterStake = sm.getStakingState();
        assertEq(stateAfterStake.stakedAmount, 200e18, "state after stake");

        sm.unstake(75e18);

        IStakingManager.StakingState memory stateAfterUnstake = sm.getStakingState();
        assertEq(stateAfterUnstake.stakedAmount, 125e18, "state after unstake");
    }

    /*//////////////////////////////////////////////////////////////
                    CAN STAKE CONFIGURABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice canStake returns true by default and is configurable.
    function test_MockSM_CanStake_Configurable() public {
        // Default: enabled
        assertTrue(sm.canStake(100e18), "canStake should return true by default");

        // Disable
        sm.mockSetCanStake(false);
        assertFalse(sm.canStake(100e18), "canStake should return false when disabled");

        // Re-enable
        sm.mockSetCanStake(true);
        assertTrue(sm.canStake(100e18), "canStake should return true when re-enabled");
    }

    /*//////////////////////////////////////////////////////////////
                 CLAIMABLE REWARDS CONFIGURABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice getClaimableRewards returns 0 by default and is configurable.
    function test_MockSM_GetClaimableRewards_Configurable() public {
        // Default: 0
        assertEq(sm.getClaimableRewards(), 0, "claimable rewards should be 0 by default");

        // Set value
        sm.mockSetClaimableRewards(42e18);
        assertEq(sm.getClaimableRewards(), 42e18, "claimable rewards should match set value");

        // Reset to 0
        sm.mockSetClaimableRewards(0);
        assertEq(sm.getClaimableRewards(), 0, "claimable rewards should reset to 0");
    }

    /*//////////////////////////////////////////////////////////////
               MOCK SET CACHED STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice mockSetCachedState updates all staking state fields.
    function test_MockSM_MockSetCachedState_AllFields() public {
        sm.mockSetCachedState(10e18, 200e18, 50e18);

        IStakingManager.StakingState memory state = sm.getStakingState();
        assertEq(state.slashingDelta, 10e18, "slashingDelta should match");
        assertEq(state.stakedAmount, 200e18, "stakedAmount should match");
        assertEq(state.pendingUnstakeAmount, 50e18, "pendingUnstakeAmount should match");

        assertEq(sm.totalStaked(), 200e18, "totalStaked should match stakedAmount");
        assertEq(sm.getSlashingDelta(), 10e18, "getSlashingDelta should match");
        assertEq(sm.pendingUnstakes(), 50e18, "pendingUnstakes should match");

        sm.mockSetHasFinalizedUnstakes(true);
        assertTrue(sm.hasFinalizedUnstakes(), "hasFinalizedUnstakes should be true when set");
    }

    /// @notice mockSetStakedAmount updates stakedAmount independently.
    function test_MockSM_MockSetStakedAmount() public {
        sm.mockSetStakedAmount(500e18);
        assertEq(sm.totalStaked(), 500e18, "totalStaked should match set value");

        IStakingManager.StakingState memory state = sm.getStakingState();
        assertEq(state.stakedAmount, 500e18, "getStakingState().stakedAmount should match");
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz: stake then unstake, totalStaked and getStakingState always consistent.
    function testFuzz_MockSM_StakeUnstakeConsistency(uint96 stakeAmt, uint96 unstakeAmt) public {
        uint256 staked = uint256(bound(stakeAmt, 0, type(uint96).max));
        uint256 unstaked = uint256(bound(unstakeAmt, 0, type(uint96).max));

        sm.stake(staked);
        sm.unstake(unstaked);

        uint256 expected = staked > unstaked ? staked - unstaked : 0;
        assertEq(sm.totalStaked(), expected, "totalStaked should be stake - min(unstake, stake)");

        IStakingManager.StakingState memory state = sm.getStakingState();
        assertEq(state.stakedAmount, expected, "getStakingState().stakedAmount should match totalStaked");
    }
}
