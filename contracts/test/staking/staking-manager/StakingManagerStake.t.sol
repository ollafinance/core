// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerStakeTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                            STAKE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Stake_RoutesAssetsToRollup() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * 2;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, stakeAmount);
        assertEq(stakingProviderRegistry.getQueueLength(), 0);
        assertEq(stakingManager.getActivatedAttesterCount(), 2);
        assertEq(aztec.balanceOf(address(rollup)), stakeAmount);
    }

    function test_Stake_LimitedByAvailableKeys() external {
        // Add only 1 key but try to stake for 2
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * 2;
        aztec.mint(core, stakeAmount);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        // Only 1 attester should be staked
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        // Remaining funds stay with core (weren't transferred)
        assertEq(aztec.balanceOf(core), coreBalanceBefore - ACTIVATION_THRESHOLD);
    }

    function test_Stake_ReturnsRoundedAmountToActivationThreshold() external {
        uint256 activationThreshold = 32 ether;
        rollup.setActivationThreshold(activationThreshold);

        IStakingManager.KeyStore[] memory keys = _createMockKeys(4);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = 100 ether;
        aztec.mint(core, stakeAmount);
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        uint256 stakedAmount = stakingManager.stake(stakeAmount);
        vm.stopPrank();

        uint256 expectedStaked = 96 ether;
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(stakedAmount, expectedStaked, "stake returns rounded amount");
        assertEq(state.stakedAmount, expectedStaked, "state uses rounded amount");
        assertEq(aztec.balanceOf(core), coreBalanceBefore - expectedStaked, "core keeps remainder");
    }

    function test_Stake_ReturnsAmountLimitedByKeys() external {
        uint256 activationThreshold = 32 ether;
        rollup.setActivationThreshold(activationThreshold);

        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = 100 ether;
        aztec.mint(core, stakeAmount);
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        uint256 stakedAmount = stakingManager.stake(stakeAmount);
        vm.stopPrank();

        uint256 expectedStaked = 64 ether;
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(stakedAmount, expectedStaked, "stake returns amount limited by keys");
        assertEq(state.stakedAmount, expectedStaked, "state uses key-limited amount");
        assertEq(aztec.balanceOf(core), coreBalanceBefore - expectedStaked, "core keeps remainder");
    }

    function test_Stake_EmitsEvent() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);

        // Filter events to only those from stakingManager (skip ERC20 Approval/Transfer events)
        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit StakedWithProvider(keys[0].attester, ACTIVATION_THRESHOLD);

        stakingManager.stake(stakeAmount);
        vm.stopPrank();
    }

    function test_RevertWhen_Stake_ZeroAmount() external {
        vm.expectRevert(IStakingManager.StakingManager__ZeroAmount.selector);
        vm.prank(core);
        stakingManager.stake(0);
    }

    function test_RevertWhen_Stake_Unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        stakingManager.stake(ACTIVATION_THRESHOLD);
    }

    function test_RevertWhen_Stake_NoKeys() external {
        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        vm.expectRevert(IStakingManager.StakingManager__InsufficientKeys.selector);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();
    }

    function test_Stake_ReturnsZeroWhen_BelowThreshold() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD - 1;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        uint256 stakedAmount = stakingManager.stake(stakeAmount);
        vm.stopPrank();

        assertEq(stakedAmount, 0);
        assertEq(stakingManager.getActivatedAttesterCount(), 0);
    }

    function test_Stake_Bounded_LowGasInitiatesSubset() external {
        uint256 attesterCount = 20;
        IStakingManager.KeyStore[] memory keys = _createMockKeys(attesterCount);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * attesterCount;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), type(uint256).max);
        vm.stopPrank();

        vm.prank(core);
        stakingManager.setGasThreshold(250_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 stakedObserved;
        uint256[6] memory gasOptions = [uint256(350_000), 450_000, 550_000, 650_000, 750_000, 850_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.stake, (stakeAmount)));
            if (!success) {
                continue;
            }
            uint256 stakedCandidate = abi.decode(data, (uint256));
            if (stakedCandidate == stakeAmount) {
                assertEq(stakedCandidate, stakeAmount, "stake should complete in one call");
                assertEq(stakingManager.getActivatedAttesterCount(), attesterCount, "all attesters should be staked");
                assertEq(stakingProviderRegistry.getQueueLength(), 0, "queue should be empty");
                return;
            }
            if (stakedCandidate > 0 && stakedCandidate < stakeAmount) {
                selectedGas = gasOptions[i];
                stakedObserved = stakedCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            uint256 stakedFull = stakingManager.stake(stakeAmount);

            assertEq(stakedFull, stakeAmount, "stake should complete in one call");
            assertEq(stakingManager.getActivatedAttesterCount(), attesterCount, "all attesters should be staked");
            assertEq(stakingProviderRegistry.getQueueLength(), 0, "queue should be empty");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(core);
        uint256 stakedAmount = stakingManager.stake{ gas: selectedGas }(stakeAmount);

        assertEq(stakedAmount, stakedObserved, "staked amount should match probe");
        assertGt(stakingManager.getActivatedAttesterCount(), 0, "should stake some attesters");
        assertLt(stakingManager.getActivatedAttesterCount(), attesterCount, "should leave keys in queue");
        assertEq(stakedAmount % ACTIVATION_THRESHOLD, 0, "staked amount should be full units");
    }

    function test_Stake_Bounded_ResumesAcrossCalls() external {
        uint256 attesterCount = 20;
        IStakingManager.KeyStore[] memory keys = _createMockKeys(attesterCount);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * attesterCount;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), type(uint256).max);
        vm.stopPrank();

        vm.prank(core);
        stakingManager.setGasThreshold(250_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[6] memory gasOptions = [uint256(350_000), 450_000, 550_000, 650_000, 750_000, 850_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.stake, (stakeAmount)));
            if (!success) {
                continue;
            }
            uint256 stakedCandidate = abi.decode(data, (uint256));
            if (stakedCandidate > 0 && stakedCandidate < stakeAmount) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            uint256 stakedFull = stakingManager.stake{ gas: 2_000_000 }(stakeAmount);

            assertEq(stakedFull, stakeAmount, "stake should complete in one call");
            assertEq(stakingManager.getActivatedAttesterCount(), attesterCount, "all attesters should be staked");
            assertEq(stakingProviderRegistry.getQueueLength(), 0, "queue should be empty");
            return;
        }

        vm.revertToState(snapshotId);
        uint256 totalStaked;
        uint256 maxIterations = 30;
        uint256 lastCount;
        uint256 gasForLoop = selectedGas;
        for (uint256 i; i < maxIterations; ++i) {
            uint256 currentCount = stakingManager.getActivatedAttesterCount();
            if (currentCount == attesterCount) {
                break;
            }
            if (currentCount == lastCount) {
                gasForLoop += 100_000;
            }
            lastCount = currentCount;
            vm.prank(core);
            totalStaked += stakingManager.stake{ gas: gasForLoop }(stakeAmount);
        }

        assertEq(stakingManager.getActivatedAttesterCount(), attesterCount, "all attesters should be staked");
        assertEq(stakingProviderRegistry.getQueueLength(), 0, "queue should be empty");
        assertEq(totalStaked, stakeAmount, "total staked should equal requested");
        assertEq(aztec.balanceOf(address(rollup)), stakeAmount, "rollup should receive staked funds");
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Stake_ValidAmount(uint8 attesterCount) external {
        attesterCount = uint8(bound(attesterCount, 1, 10));

        IStakingManager.KeyStore[] memory keys = _createMockKeys(attesterCount);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * attesterCount;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, stakeAmount);
        assertEq(stakingManager.getActivatedAttesterCount(), attesterCount);
    }
}
