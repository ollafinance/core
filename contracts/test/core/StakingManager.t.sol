// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { StakingManager } from "src/core/StakingManager.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/mocks/MockAztecRollupRegistry.sol";
import { G1Point, G2Point } from "src/libraries/BN254Lib.sol";

contract StakingManagerTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant ACTIVATION_THRESHOLD = 100 ether;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    MockAztec internal aztec;
    MockAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    StakingManager internal stakingManager;

    address internal core;
    address internal providerAdmin;
    address internal rewardsVault;
    address internal defaultAdmin;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProviderSet(address indexed admin, address indexed rewardsRecipient);
    event KeysAddedToProvider(address[] attesters);
    event StakedWithProvider(address indexed attester, uint256 amount);
    event UnstakeInitiated(address indexed attester, uint256 amount);
    event UnstakeFinalized(address indexed attester, uint256 amount);
    event UnstakedFundsClaimed(uint256 amount);
    event RewardsHarvested(uint256 amount);
    event QueueDripped(address indexed attester);

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        rewardsVault = makeAddr("rewardsVault");
        defaultAdmin = makeAddr("defaultAdmin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        aztec = new MockAztec(address(this));
        rollup = new MockAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        rollupRegistry = new MockAztecRollupRegistry(address(rollup));

        stakingManager = new StakingManager(
            IERC20(address(aztec)),
            address(rollupRegistry),
            rewardsVault,
            core,
            providerAdmin,
            providerAdmin, // rewardsRecipient same as admin for simplicity
            defaultAdmin
        );
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _createMockKeys(uint256 count) internal pure returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = IStakingManager.KeyStore({
                attester: address(uint160(i + 1)),
                publicKeyG1: G1Point({ x: i, y: i + 1 }),
                publicKeyG2: G2Point({ x0: i, x1: i + 1, y0: i + 2, y1: i + 3 }),
                proofOfPossession: G1Point({ x: i + 10, y: i + 11 })
            });
        }
        return keys;
    }

    function _setupStakedAttester() internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();
    }

    function _setupMultipleStakedAttesters(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * count;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();
    }

    function _setupStakedAttestersWithExits(uint256 total, uint256 exited) internal {
        require(exited <= total, "exited cannot be more than total");
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD * total);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD * total);
        stakingManager.stake(ACTIVATION_THRESHOLD * total);
        vm.stopPrank();

        // Simulate external exits for the first 'exited' attesters
        for (uint256 i = 0; i < exited; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD, block.timestamp);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsImmutables() external view {
        assertEq(address(stakingManager.STAKING_ASSET()), address(aztec));
        assertEq(address(stakingManager.ROLLUP_REGISTRY()), address(rollupRegistry));
        assertEq(stakingManager.REWARDS_VAULT(), rewardsVault);
        assertEq(stakingManager.CORE(), core);
    }

    function test_Constructor_SetsProviderConfig() external view {
        IStakingManager.ProviderConfig memory config = stakingManager.getProviderConfig();
        assertEq(config.admin, providerAdmin);
        assertEq(config.rewardsRecipient, providerAdmin);
    }

    function test_Constructor_GrantsRoles() external view {
        assertTrue(stakingManager.hasRole(stakingManager.DEFAULT_ADMIN_ROLE(), defaultAdmin));
        assertTrue(stakingManager.hasRole(stakingManager.CORE_ROLE(), core));
        assertTrue(stakingManager.hasRole(stakingManager.STAKING_PROVIDER_ADMIN_ROLE(), providerAdmin));
    }

    function test_Constructor_EmitsProviderSet() external {
        vm.expectEmit(true, true, true, true);
        emit ProviderSet(providerAdmin, providerAdmin);

        new StakingManager(
            IERC20(address(aztec)),
            address(rollupRegistry),
            rewardsVault,
            core,
            providerAdmin,
            providerAdmin,
            defaultAdmin
        );
    }

    function test_RevertWhen_ConstructorZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "stakingAsset"));
        new StakingManager(
            IERC20(address(0)), address(rollupRegistry), rewardsVault, core, providerAdmin, providerAdmin, defaultAdmin
        );

        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "rollupRegistry"));
        new StakingManager(
            IERC20(address(aztec)), address(0), rewardsVault, core, providerAdmin, providerAdmin, defaultAdmin
        );

        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "rewardsVault"));
        new StakingManager(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(0),
            core,
            providerAdmin,
            providerAdmin,
            defaultAdmin
        );

        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "core"));
        new StakingManager(
            IERC20(address(aztec)),
            address(rollupRegistry),
            rewardsVault,
            address(0),
            providerAdmin,
            providerAdmin,
            defaultAdmin
        );

        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "providerAdmin"));
        new StakingManager(
            IERC20(address(aztec)), address(rollupRegistry), rewardsVault, core, address(0), providerAdmin, defaultAdmin
        );

        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "defaultAdmin"));
        new StakingManager(
            IERC20(address(aztec)),
            address(rollupRegistry),
            rewardsVault,
            core,
            providerAdmin,
            providerAdmin,
            address(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                      PROVIDER ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddKeysToProvider_AddsKeys() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(3);

        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        assertEq(stakingManager.getQueueLength(), 3);
    }

    function test_AddKeysToProvider_EmitsEvent() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        address[] memory expectedAttesters = new address[](2);
        expectedAttesters[0] = keys[0].attester;
        expectedAttesters[1] = keys[1].attester;

        vm.expectEmit(true, true, true, true);
        emit KeysAddedToProvider(expectedAttesters);

        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);
    }

    function test_RevertWhen_AddKeysToProvider_Unauthorized() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                stakingManager.STAKING_PROVIDER_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        stakingManager.addKeysToProvider(keys);
    }

    function test_RevertWhen_AddKeysToProvider_EmptyArray() external {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](0);

        vm.expectRevert(IStakingManager.StakingManager__ZeroAmount.selector);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);
    }

    function test_DripQueue_RemovesKeys() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(5);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        vm.prank(providerAdmin);
        stakingManager.dripQueue(2);

        assertEq(stakingManager.getQueueLength(), 3);
    }

    function test_DripQueue_EmitsEvents() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        vm.expectEmit(true, true, true, true);
        emit QueueDripped(keys[0].attester);
        vm.expectEmit(true, true, true, true);
        emit QueueDripped(keys[1].attester);

        vm.prank(providerAdmin);
        stakingManager.dripQueue(2);
    }

    function test_RevertWhen_DripQueue_Empty() external {
        vm.expectRevert(IStakingManager.StakingManager__QueueEmpty.selector);
        vm.prank(providerAdmin);
        stakingManager.dripQueue(1);
    }

    function test_SetProviderRewardsRecipient() external {
        vm.expectEmit(true, true, true, true);
        emit ProviderSet(providerAdmin, alice);

        vm.prank(providerAdmin);
        stakingManager.setProviderRewardsRecipient(alice);

        IStakingManager.ProviderConfig memory config = stakingManager.getProviderConfig();
        assertEq(config.rewardsRecipient, alice);
    }

    function test_RevertWhen_SetProviderRewardsRecipient_ZeroAddress() external {
        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "rewardsRecipient")
        );
        vm.prank(providerAdmin);
        stakingManager.setProviderRewardsRecipient(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                         STAKE FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Stake_RoutesAssetsToRollup() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * 2;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, stakeAmount);
        assertEq(stakingManager.getQueueLength(), 0);
        assertEq(stakingManager.getActivatedAttesterCount(), 2);
        assertEq(aztec.balanceOf(address(rollup)), stakeAmount);
    }

    function test_Stake_LimitedByAvailableKeys() external {
        // Add only 1 key but try to stake for 2
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * 2;
        aztec.mint(core, stakeAmount);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        // Only 1 attester should be staked
        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        // Remaining funds stay with core (weren't transferred)
        assertEq(aztec.balanceOf(core), coreBalanceBefore - ACTIVATION_THRESHOLD);
    }

    function test_Stake_EmitsEvent() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);

        vm.expectEmit(true, true, true, true);
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
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, stakingManager.CORE_ROLE()
            )
        );
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

    function test_RevertWhen_Stake_BelowThreshold() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD - 1;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        vm.expectRevert(IStakingManager.StakingManager__InsufficientAmount.selector);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        UNSTAKE FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Unstake_InitiatesWithdrawal() external {
        _setupStakedAttester();

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.stakedAmount, stateBefore.stakedAmount - ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), 1);
    }

    function test_Unstake_EmitsEvent() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);

        vm.expectEmit(true, true, true, true);
        emit UnstakeInitiated(keys[0].attester, ACTIVATION_THRESHOLD);

        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.expectEmit(true, true, true, true);
        emit UnstakeFinalized(keys[0].attester, ACTIVATION_THRESHOLD);

        stakingManager.getUnstakedFunds();
        vm.stopPrank();
    }

    function test_RevertWhen_Unstake_ExceedsStaked() external {
        vm.prank(core);
        vm.expectRevert(IStakingManager.StakingManager__InsufficientStake.selector);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
    }

    function test_RevertWhen_Unstake_ZeroAmount() external {
        vm.expectRevert(IStakingManager.StakingManager__ZeroAmount.selector);
        vm.prank(core);
        stakingManager.unstake(0);
    }

    function test_RevertWhen_Unstake_Unauthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, stakingManager.CORE_ROLE()
            )
        );
        vm.prank(alice);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
    }

    function test_Unstake_MultipleAttesters() external {
        _setupMultipleStakedAttesters(3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        assertEq(stakingManager.getPendingUnstakeCount(), 2);
    }

    function test_IsUnstakePending() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);

        assertFalse(stakingManager.isUnstakePending(keys[0].attester));

        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        assertTrue(stakingManager.isUnstakePending(keys[0].attester));
    }

    /*//////////////////////////////////////////////////////////////
                    GET UNSTAKED FUNDS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetUnstakedFunds_ClaimsMaturedWithdrawals() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_GetUnstakedFunds_EmitsEvent() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.expectEmit(true, true, true, true);
        emit UnstakedFundsClaimed(ACTIVATION_THRESHOLD);

        vm.prank(core);
        stakingManager.getUnstakedFunds();
    }

    function test_GetUnstakedFunds_ReturnsZeroWhenNoPending() external {
        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();
        assertEq(claimed, 0);
    }

    function test_GetUnstakedFunds_MultipleAttesters() external {
        _setupMultipleStakedAttesters(3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 3);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD * 3);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD * 3);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        HARVEST REWARDS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HarvestRewards_ReturnsZero() external {
        // Placeholder implementation returns 0
        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();
        assertEq(harvested, 0);
    }

    function test_HarvestRewards_EmitsEvent() external {
        vm.expectEmit(true, true, true, true);
        emit RewardsHarvested(0);

        vm.prank(core);
        stakingManager.harvestRewards();
    }

    function test_RevertWhen_HarvestRewards_Unauthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, stakingManager.CORE_ROLE()
            )
        );
        vm.prank(alice);
        stakingManager.harvestRewards();
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetStakingState_InitiallyZero() external view {
        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, 0);
        assertEq(state.pendingUnstakeAmount, 0);
        assertEq(state.withdrawableAmount, 0);
    }

    function test_GetQueueLength_InitiallyZero() external view {
        assertEq(stakingManager.getQueueLength(), 0);
    }

    function test_GetActivatedAttesterCount_InitiallyZero() external view {
        assertEq(stakingManager.getActivatedAttesterCount(), 0);
    }

    function test_GetPendingUnstakeCount_InitiallyZero() external view {
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Stake_ValidAmount(uint8 attesterCount) external {
        attesterCount = uint8(bound(attesterCount, 1, 10));

        IStakingManager.KeyStore[] memory keys = _createMockKeys(attesterCount);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * attesterCount;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, stakeAmount);
        assertEq(stakingManager.getActivatedAttesterCount(), attesterCount);
    }

    function testFuzz_UnstakeAfterStake(uint8 stakeCount, uint8 unstakeCount) external {
        stakeCount = uint8(bound(stakeCount, 1, 10));
        unstakeCount = uint8(bound(unstakeCount, 1, stakeCount));

        _setupMultipleStakedAttesters(stakeCount);

        uint256 unstakeAmount = ACTIVATION_THRESHOLD * unstakeCount;

        vm.prank(core);
        stakingManager.unstake(unstakeAmount);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * (stakeCount - unstakeCount));
        assertEq(stakingManager.getActivatedAttesterCount(), stakeCount - unstakeCount);
    }

    /*//////////////////////////////////////////////////////////////
                     GET STAKING STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetStakingState_ReturnsCorrectValuesAfterStake() external {
        _setupMultipleStakedAttesters(3);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * 3);
        assertEq(state.pendingUnstakeAmount, 0);
        assertEq(state.withdrawableAmount, 0);
    }

    function test_GetStakingState_ReturnsCorrectValuesAfterUnstake() external {
        _setupMultipleStakedAttesters(3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD);
        // In the mock, exitableAt is set to block.timestamp (immediate), so it's withdrawable
        assertEq(state.pendingUnstakeAmount, 0);
        assertEq(state.withdrawableAmount, ACTIVATION_THRESHOLD * 2);
    }

    function test_GetStakingState_ReturnsCorrectValuesWithDelayedExit() external {
        _setupMultipleStakedAttesters(2);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Set exit to be in the future for the attester that was unstaked
        // The unstake logic picks from the front of the array, so it's keys[0].attester (address(1))
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD);
        assertEq(state.pendingUnstakeAmount, ACTIVATION_THRESHOLD);
        assertEq(state.withdrawableAmount, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            CLEAN ACTIVATED ATTESTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CleanActivatedAttesters_RemovesExitedAttesters() external {
        uint256 total = 3;
        uint256 exited = 2;
        _setupStakedAttestersWithExits(total, exited);

        vm.prank(core);
        stakingManager.cleanActivatedAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), total - exited);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);
    }

    function test_CleanActivatedAttesters_NoExits() external {
        _setupMultipleStakedAttesters(2);

        uint256 activatedBefore = stakingManager.getActivatedAttesterCount();
        uint256 pendingBefore = stakingManager.getPendingUnstakeCount();

        vm.prank(core);
        stakingManager.cleanActivatedAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), activatedBefore);
        assertEq(stakingManager.getPendingUnstakeCount(), pendingBefore);
    }

    function test_CleanActivatedAttesters_AllExits() external {
        uint256 total = 2;
        uint256 exited = 2;
        _setupStakedAttestersWithExits(total, exited);

        vm.prank(core);
        stakingManager.cleanActivatedAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);
    }

    function test_CleanActivatedAttesters_EmptyActivated() external {
        vm.prank(core);
        stakingManager.cleanActivatedAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_RevertWhen_CleanActivatedAttesters_Unauthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, stakingManager.CORE_ROLE()
            )
        );
        vm.prank(alice);
        stakingManager.cleanActivatedAttesters();
    }
}
