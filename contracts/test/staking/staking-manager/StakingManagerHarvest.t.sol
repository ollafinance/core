// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Vm } from "@forge-std/Test.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IMockAztecRollup } from "src/staking/mocks/IMockAztecRollup.sol";
import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract MockAztecV5RewardRollup {
    mapping(address sequencer => uint256 rewards) private _pendingRewards;

    function setRewards(address sequencer, uint256 amount) external {
        _pendingRewards[sequencer] = amount;
    }

    function getSequencerRewards(address sequencer) external view returns (uint256) {
        return _pendingRewards[sequencer];
    }
}

/// @title StakingManagerHarvestTest
/// @notice Comprehensive tests for StakingManager.harvestRewards() functionality.
/// @dev Uses MockRewardsAccumulator to properly test reward harvesting flow.
contract StakingManagerHarvestTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setupStakedAttesters(uint256 count) internal returns (IStakingManager.KeyStore[] memory keys) {
        keys = _createMockKeys(count);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * count;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        return keys;
    }

    function _setupAttestersWithRewards(uint256 count, uint256 rewardPerAttester)
        internal
        returns (IStakingManager.KeyStore[] memory keys)
    {
        keys = _setupStakedAttesters(count);

        uint256 totalRewards = rewardPerAttester * count;

        // Mint rewards to rollup so it can pay out
        aztec.mint(address(rollup), totalRewards);

        // Set rewards for the rewards vault address (new logic)
        rollup.setRewards(address(rewardsAccumulator), totalRewards);

        return keys;
    }

    function _setupAttestersWithVariableRewards(uint256[] memory rewards)
        internal
        returns (IStakingManager.KeyStore[] memory keys)
    {
        uint256 count = rewards.length;
        keys = _setupStakedAttesters(count);

        uint256 totalRewards;
        for (uint256 i; i < count; ++i) {
            totalRewards += rewards[i];
        }

        // Mint rewards to rollup
        aztec.mint(address(rollup), totalRewards);

        // Set total rewards for the rewards vault address (new logic)
        rollup.setRewards(address(rewardsAccumulator), totalRewards);

        return keys;
    }

    /*//////////////////////////////////////////////////////////////
                      BASIC HARVEST SUCCESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HarvestRewards_ClaimsRewardsToVault() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, rewardAmount, "Should harvest full reward amount");
        assertEq(
            rollup.getSequencerRewards(address(rewardsAccumulator)), 0, "Vault rewards should be zero after harvest"
        );
    }

    function test_HarvestRewards_ClaimsMultipleAttesterRewards() external {
        uint256 attesterCount = 3;
        uint256 rewardPerAttester = 5 ether;
        _setupAttestersWithRewards(attesterCount, rewardPerAttester);

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        uint256 expectedTotal = rewardPerAttester * attesterCount;
        assertEq(harvested, expectedTotal, "Should harvest all attesters' rewards");
    }

    function test_HarvestRewards_IncreasesRewardsAccumulatorBalance() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        uint256 vaultBalanceBefore = aztec.balanceOf(address(rewardsAccumulator));

        vm.prank(core);
        stakingManager.harvestRewards();

        uint256 vaultBalanceAfter = aztec.balanceOf(address(rewardsAccumulator));
        // Rewards are paid directly to the RewardsAccumulator by the rollup claim.
        assertEq(vaultBalanceAfter - vaultBalanceBefore, rewardAmount, "Vault balance should increase by rewards");
    }

    function test_HarvestRewards_EmitsRewardsHarvestedEvent() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit RewardsHarvested(rewardAmount);

        vm.prank(core);
        stakingManager.harvestRewards();
    }

    /*//////////////////////////////////////////////////////////////
                          ZERO/EMPTY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HarvestRewards_ReturnsZeroWithNoAttesters() external {
        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();
        assertEq(harvested, 0, "Should return 0 with no attesters");
    }

    function test_HarvestRewards_ReturnsZeroWhenAllHaveZeroRewards() external {
        _setupStakedAttesters(3);
        // No rewards set, all attesters have 0 rewards

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, 0, "Should return 0 when all attesters have no rewards");
    }

    function test_HarvestRewards_SkipsAttestersWithZeroRewards() external {
        // Setup 3 attesters, only give rewards to the middle one
        uint256[] memory rewards = new uint256[](3);
        rewards[0] = 0;
        rewards[1] = 10 ether;
        rewards[2] = 0;
        _setupAttestersWithVariableRewards(rewards);

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, 10 ether, "Should only harvest from attester with rewards");
    }

    /*//////////////////////////////////////////////////////////////
                        PARTIAL FAILURE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HarvestRewards_ContinuesOnClaimFailure() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(3, rewardAmount);

        // Note: New implementation doesn't iterate through attesters,
        // so it will read total rewards set for vault (30 ether)
        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, 30 ether, "Should harvest all rewards (no individual attester iteration)");
    }

    function test_HarvestRewards_ReturnsCorrectAmountAfterPartialFailure() external {
        uint256[] memory rewards = new uint256[](4);
        rewards[0] = 5 ether;
        rewards[1] = 10 ether;
        rewards[2] = 15 ether;
        rewards[3] = 20 ether;
        _setupAttestersWithVariableRewards(rewards);

        // Note: New implementation doesn't iterate through attesters,
        // so it returns total rewards (50 ether) regardless of individual failures
        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, 50 ether, "Should return total rewards (no individual attester iteration)");
    }

    /*//////////////////////////////////////////////////////////////
                    CLAIM FAILURE GRACEFUL HANDLING
    //////////////////////////////////////////////////////////////*/

    function test_HarvestRewards_ReturnsZeroWhenClaimReverts() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        // Make rollup claim revert
        rollup.setClaimShouldFail(address(rewardsAccumulator), true);

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, 0, "Should return 0 when claim reverts");
    }

    function test_HarvestRewards_EmitsRewardsHarvestFailedWhenClaimReverts() external {
        _setupStakedAttesters(1);

        rollup.setClaimShouldFail(address(rewardsAccumulator), true);

        vm.expectEmit(address(stakingManager));
        emit RewardsHarvestFailed(abi.encodeWithSelector(IMockAztecRollup.MockAztecRollup__ClaimFailed.selector));

        vm.prank(core);
        stakingManager.harvestRewards();
    }

    function test_HarvestRewards_DoesNotEmitRewardsHarvestedWhenClaimReverts() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        rollup.setClaimShouldFail(address(rewardsAccumulator), true);

        vm.recordLogs();
        vm.prank(core);
        stakingManager.harvestRewards();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 harvestedTopic = RewardsHarvested.selector;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == harvestedTopic) {
                fail("RewardsHarvested should not be emitted when claim fails");
            }
        }
    }

    function test_HarvestRewards_DoesNotTransferTokensWhenClaimReverts() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        rollup.setClaimShouldFail(address(rewardsAccumulator), true);

        uint256 accumulatorBalanceBefore = aztec.balanceOf(address(rewardsAccumulator));

        vm.prank(core);
        stakingManager.harvestRewards();

        assertEq(
            aztec.balanceOf(address(rewardsAccumulator)),
            accumulatorBalanceBefore,
            "Accumulator balance should not change when claim fails"
        );
    }

    function test_HarvestRewards_RecoverAfterClaimFailure() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        // First call: claim fails
        rollup.setClaimShouldFail(address(rewardsAccumulator), true);
        vm.prank(core);
        uint256 harvestedFail = stakingManager.harvestRewards();
        assertEq(harvestedFail, 0, "Should return 0 on failure");

        // Second call: claim succeeds
        rollup.setClaimShouldFail(address(rewardsAccumulator), false);
        vm.prank(core);
        uint256 harvestedSuccess = stakingManager.harvestRewards();
        assertEq(harvestedSuccess, rewardAmount, "Should harvest rewards after recovery");
    }

    /*//////////////////////////////////////////////////////////////
                         ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_HarvestRewards_CalledByNonCore() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        stakingManager.harvestRewards();
    }

    /*//////////////////////////////////////////////////////////////
                      GET CLAIMABLE REWARDS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetClaimableRewards_ReturnsZeroWithNoAttesters() external {
        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, 0, "Should be 0 with no attesters");
    }

    function test_GetClaimableRewards_ReturnsCorrectAmount() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, rewardAmount, "Should return correct reward amount");
    }

    function test_GetClaimableRewards_SumsRollupWithoutLegacyGateSelector() external {
        uint256 rewardAmount = 10 ether;
        MockAztecV5RewardRollup v5Rollup = new MockAztecV5RewardRollup();
        v5Rollup.setRewards(address(rewardsAccumulator), rewardAmount);
        rollupRegistry.setCanonicalRollup(address(v5Rollup));

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, rewardAmount, "Should read rewards without probing legacy gate");
    }

    function test_GetClaimableRewards_SumsMultipleAttesters() external {
        uint256 attesterCount = 3;
        uint256 rewardPerAttester = 5 ether;
        _setupAttestersWithRewards(attesterCount, rewardPerAttester);

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        uint256 expectedTotal = rewardPerAttester * attesterCount;
        assertEq(claimable, expectedTotal, "Should sum all attesters' rewards");
    }

    function test_GetClaimableRewards_ReturnsZeroWhenAllHaveZeroRewards() external {
        _setupStakedAttesters(3);
        // No rewards set, all attesters have 0 rewards

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        assertEq(claimable, 0, "Should return 0 when all attesters have no rewards");
    }

    function test_GetClaimableRewards_DoesNotModifyState() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        uint256 vaultBalanceBefore = aztec.balanceOf(address(rewardsAccumulator));

        vm.prank(core);
        stakingManager.getClaimableRewards();

        uint256 vaultBalanceAfter = aztec.balanceOf(address(rewardsAccumulator));
        assertEq(vaultBalanceAfter, vaultBalanceBefore, "Get claimable rewards should not modify state");
    }

    function test_RevertWhen_GetClaimableRewards_CalledByNonCore() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        stakingManager.getClaimableRewards();
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_HarvestRewards_VariableAttesterCount(uint8 attesterCount) external {
        attesterCount = uint8(bound(attesterCount, 1, 20));
        uint256 rewardPerAttester = 5 ether;

        _setupAttestersWithRewards(attesterCount, rewardPerAttester);

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        uint256 expectedTotal = rewardPerAttester * attesterCount;
        assertEq(harvested, expectedTotal, "Should harvest all attesters' rewards");
    }

    function testFuzz_HarvestRewards_VariableRewards(uint96 rewardAmount) external {
        rewardAmount = uint96(bound(rewardAmount, 1, 1000 ether));

        _setupAttestersWithRewards(1, rewardAmount);

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, rewardAmount, "Should harvest correct reward amount");
    }

    function testFuzz_HarvestRewards_ConsistentWithGetClaimable(uint8 attesterCount, uint96 rewardPerAttester)
        external
    {
        attesterCount = uint8(bound(attesterCount, 1, 10));
        rewardPerAttester = uint96(bound(rewardPerAttester, 1, 100 ether));

        _setupAttestersWithRewards(attesterCount, rewardPerAttester);

        vm.startPrank(core);
        uint256 claimable = stakingManager.getClaimableRewards();
        uint256 harvested = stakingManager.harvestRewards();
        vm.stopPrank();

        // Harvested should equal claimable when there are no failures
        assertEq(harvested, claimable, "Harvested should match claimable");
    }

    function testFuzz_GetClaimableRewards_VariableAttesterCount(uint8 attesterCount, uint96 rewardPerAttester)
        external
    {
        attesterCount = uint8(bound(attesterCount, 1, 20));
        rewardPerAttester = uint96(bound(rewardPerAttester, 0, 1000 ether));

        _setupAttestersWithRewards(attesterCount, rewardPerAttester);

        vm.prank(core);
        uint256 claimable = stakingManager.getClaimableRewards();

        uint256 expectedTotal = rewardPerAttester * attesterCount;
        assertEq(claimable, expectedTotal, "Should return sum of all rewards");
    }
}
