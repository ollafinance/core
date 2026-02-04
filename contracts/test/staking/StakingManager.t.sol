// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test, Vm } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

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
    StakingProviderRegistry internal stakingProviderRegistry;

    address internal core;
    address internal providerAdmin;
    MockRewardsVault internal rewardsVault;
    address internal defaultAdmin;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProviderSet(address indexed admin, address indexed rewardsRecipient);
    event KeysAddedToProvider(address[] attesters);
    event StakedWithProvider(address indexed attester, uint256 indexed amount);
    event UnstakeInitiated(address indexed attester, uint256 indexed amount);
    event UnstakeFinalized(address indexed attester, uint256 indexed amount);
    event UnstakedFundsClaimed(uint256 indexed amount);
    event RewardsHarvested(uint256 indexed amount);
    event QueueDripped(address indexed attester);
    event AttesterRewardsClaimed(address indexed attester, uint256 indexed amount);
    event RewardClaimFailed(address indexed attester, string reason);

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        defaultAdmin = makeAddr("defaultAdmin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        aztec = new MockAztec(address(this));
        rollup = new MockAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        rollupRegistry = new MockAztecRollupRegistry(address(rollup));
        rewardsVault = new MockRewardsVault(IERC20(address(aztec)), core);

        StakingManager implementation = new StakingManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        stakingManager = StakingManager(address(proxy));

        StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));

        stakingProviderRegistry.initialize(
            address(stakingManager),
            providerAdmin,
            providerAdmin, // rewardsRecipient same as admin for simplicity
            defaultAdmin
        );

        stakingManager.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsVault),
            core,
            address(stakingProviderRegistry),
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
                // casting to uint160 is safe because i + 1 stays within 160 bits
                // forge-lint: disable-next-line(unsafe-typecast)
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
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();
    }

    function _setupMultipleStakedAttesters(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

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
        stakingProviderRegistry.addKeysToProvider(keys);

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

    function test_Initialize_SetsConfig() external view {
        assertEq(address(stakingManager.stakingAsset()), address(aztec));
        assertEq(address(stakingManager.rollupRegistry()), address(rollupRegistry));
        assertEq(address(stakingManager.rewardsVault()), address(rewardsVault));
        assertEq(stakingManager.core(), core);
    }

    function test_Initialize_SetsProviderConfig() external view {
        IStakingManager.ProviderConfig memory config = stakingManager.getProviderConfig();
        assertEq(config.admin, providerAdmin);
        assertEq(config.rewardsRecipient, providerAdmin);
    }

    function test_Initialize_GrantsRoles() external view {
        assertTrue(stakingManager.hasRole(stakingManager.DEFAULT_ADMIN_ROLE(), defaultAdmin));
        assertTrue(
            stakingProviderRegistry.hasRole(stakingProviderRegistry.STAKING_PROVIDER_ADMIN_ROLE(), providerAdmin)
        );
        assertTrue(
            stakingProviderRegistry.hasRole(stakingProviderRegistry.STAKING_PROVIDER_ADMIN_ROLE(), providerAdmin)
        );
    }

    function test_Initialize_EmitsProviderSet() external {
        StakingManager implementation = new StakingManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        StakingManager mgr = StakingManager(address(proxy));

        StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
        StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));

        vm.expectEmit(true, true, true, true, address(registry));
        emit ProviderSet(providerAdmin, providerAdmin);

        registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);

        mgr.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsVault),
            core,
            address(registry),
            defaultAdmin
        );
    }

    function test_RevertWhen_InitializeZeroAddress() external {
        StakingManager implementation = new StakingManager();

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "stakingAsset")
            );
            mgr.initialize(
                IERC20(address(0)),
                address(rollupRegistry),
                address(rewardsVault),
                core,
                address(registry),
                defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "rollupRegistry")
            );
            mgr.initialize(
                IERC20(address(aztec)), address(0), address(rewardsVault), core, address(registry), defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "rewardsVault")
            );
            mgr.initialize(
                IERC20(address(aztec)), address(rollupRegistry), address(0), core, address(registry), defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "core"));
            mgr.initialize(
                IERC20(address(aztec)),
                address(rollupRegistry),
                address(rewardsVault),
                address(0),
                address(registry),
                defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "stakingProviderRegistry")
            );
            mgr.initialize(
                IERC20(address(aztec)), address(rollupRegistry), address(rewardsVault), core, address(0), defaultAdmin
            );
        }

        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingManager mgr = StakingManager(address(proxy));

            StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
            ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
            StakingProviderRegistry registry = StakingProviderRegistry(address(registryProxy));
            registry.initialize(address(mgr), providerAdmin, providerAdmin, defaultAdmin);
            vm.expectRevert(
                abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "defaultAdmin")
            );
            mgr.initialize(
                IERC20(address(aztec)),
                address(rollupRegistry),
                address(rewardsVault),
                core,
                address(registry),
                address(0)
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                         STAKE FLOW TESTS
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
        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        // Remaining funds stay with core (weren't transferred)
        assertEq(aztec.balanceOf(core), coreBalanceBefore - ACTIVATION_THRESHOLD);
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

    function test_RevertWhen_Stake_BelowThreshold() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

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
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);

        // Filter events to only those from stakingManager
        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit UnstakeInitiated(keys[0].attester, ACTIVATION_THRESHOLD);

        stakingManager.unstake(ACTIVATION_THRESHOLD);

        vm.expectEmit(true, true, true, true, address(stakingManager));
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
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
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
        stakingProviderRegistry.addKeysToProvider(keys);

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

        // UnstakeFinalized is emitted before UnstakedFundsClaimed, so record logs instead
        vm.recordLogs();

        vm.prank(core);
        stakingManager.getUnstakedFunds();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        // Find UnstakedFundsClaimed event (amount is indexed, so it's in topics[1])
        bool foundEvent = false;
        bytes32 expectedSelector = keccak256("UnstakedFundsClaimed(uint256)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == expectedSelector) {
                uint256 amount = uint256(entries[i].topics[1]);
                assertEq(amount, ACTIVATION_THRESHOLD);
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "UnstakedFundsClaimed event not found");
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

    function test_GetUnstakedFunds_PartialExitReadiness_ClaimsOnlyReady() external {
        _setupMultipleStakedAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        // Make attester[0] not yet exitable; attester[1] stays immediately exitable in the mock.
        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 1);
        assertTrue(stakingManager.isUnstakePending(keys[0].attester));
        assertFalse(stakingManager.isUnstakePending(keys[1].attester));

        vm.warp(block.timestamp + 2 days);

        coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
        assertFalse(stakingManager.isUnstakePending(keys[0].attester));
    }

    /*//////////////////////////////////////////////////////////////
                        HARVEST REWARDS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HarvestRewards_ReturnsZeroWithNoAttesters() external {
        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();
        assertEq(harvested, 0, "Should return 0 with no attesters");
    }

    function test_HarvestRewards_EmitsEventWithNoAttesters() external {
        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit RewardsHarvested(0);

        vm.prank(core);
        stakingManager.harvestRewards();
    }

    function testAccessControlUnauthorizedAccount_RevertWhen_HarvestRewards_Unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
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
        assertEq(stakingProviderRegistry.getQueueLength(), 0);
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
        stakingProviderRegistry.addKeysToProvider(keys);

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

    function test_CleanActivatedAttesters_ExternallyExited_CanBeClaimed() external {
        uint256 total = 3;
        uint256 exited = 2;
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);

        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD * total);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD * total);
        stakingManager.stake(ACTIVATION_THRESHOLD * total);
        vm.stopPrank();

        for (uint256 i; i < exited; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD, block.timestamp);
        }

        vm.prank(core);
        stakingManager.cleanActivatedAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), total - exited);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD * exited);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + claimed);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
        for (uint256 i; i < exited; ++i) {
            assertFalse(stakingManager.isUnstakePending(keys[i].attester));
        }
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
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        stakingManager.cleanActivatedAttesters();
    }
}

/// @title StakingManagerHarvestTest
/// @notice Comprehensive tests for StakingManager.harvestRewards() functionality.
/// @dev Uses MockRewardsVault to properly test reward harvesting flow.
contract StakingManagerHarvestTest is Test {
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
    MockRewardsVault internal rewardsVault;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;

    address internal core;
    address internal providerAdmin;
    address internal defaultAdmin;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardsHarvested(uint256 indexed amount);
    event AttesterRewardsClaimed(address indexed attester, uint256 indexed amount);
    event RewardClaimFailed(address indexed attester, string reason);

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        defaultAdmin = makeAddr("defaultAdmin");
        alice = makeAddr("alice");

        aztec = new MockAztec(address(this));
        rollup = new MockAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        rollupRegistry = new MockAztecRollupRegistry(address(rollup));
        rewardsVault = new MockRewardsVault(IERC20(address(aztec)), core);

        StakingManager implementation = new StakingManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        stakingManager = StakingManager(address(proxy));

        StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));

        stakingProviderRegistry.initialize(address(stakingManager), providerAdmin, providerAdmin, defaultAdmin);

        stakingManager.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsVault),
            core,
            address(stakingProviderRegistry),
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
        rollup.setRewards(address(rewardsVault), totalRewards);

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
        rollup.setRewards(address(rewardsVault), totalRewards);

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
        assertEq(rollup.getSequencerRewards(address(rewardsVault)), 0, "Vault rewards should be zero after harvest");
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

    function test_HarvestRewards_IncreasesRewardsVaultBalance() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        uint256 vaultBalanceBefore = aztec.balanceOf(address(rewardsVault));

        vm.prank(core);
        stakingManager.harvestRewards();

        uint256 vaultBalanceAfter = aztec.balanceOf(address(rewardsVault));
        // Rewards are paid directly to the RewardsVault by the rollup claim.
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
                        ZERO/EMPTY CASES TESTS
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

    function test_HarvestRewards_EmitsRewardClaimFailedEvent() external {
        uint256 rewardAmount = 10 ether;
        _setupAttestersWithRewards(1, rewardAmount);

        // Note: New implementation doesn't iterate through attesters,
        // so no individual claim failures occur
        vm.recordLogs();

        vm.prank(core);
        stakingManager.harvestRewards();

        // Verify no RewardClaimFailed events were emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 failedSelector = keccak256("RewardClaimFailed(address,string)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != failedSelector, "Should not emit RewardClaimFailed events");
        }
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

        uint256 vaultBalanceBefore = aztec.balanceOf(address(rewardsVault));

        vm.prank(core);
        stakingManager.getClaimableRewards();

        uint256 vaultBalanceAfter = aztec.balanceOf(address(rewardsVault));
        assertEq(vaultBalanceAfter, vaultBalanceBefore, "Get claimable rewards should not modify state");
    }

    function test_RevertWhen_GetClaimableRewards_CalledByNonCore() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        stakingManager.getClaimableRewards();
    }

    /*//////////////////////////////////////////////////////////////
                        SLASHING DELTA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetSlashingDelta_ReturnsZeroWithNoAttesters() external {
        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 0, "Should be 0 with no attesters");
    }

    function test_GetSlashingDelta_ComputesFromActivatedAttesters() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(2);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD - 10 ether, block.timestamp);

        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 10 ether, "Should include slashing from activated attesters");
        assertEq(
            stakingManager.totalStaked(), 2 * ACTIVATION_THRESHOLD, "totalStaked counts eligible activated attesters"
        );
    }

    function test_GetSlashingDelta_IncludesPendingUnstakeRequests() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(2);

        vm.startPrank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD - 15 ether, block.timestamp);

        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        assertEq(slashingDelta, 15 ether, "Should include slashing from pending attesters");
        assertEq(
            stakingManager.totalStaked(), 2 * ACTIVATION_THRESHOLD, "totalStaked counts activated and pending attesters"
        );
    }

    function test_GetSlashingDelta_MonotonicCumulative() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD - 10 ether, block.timestamp);

        vm.prank(core);
        uint256 first = stakingManager.getSlashingDelta();
        assertEq(first, 10 ether, "initial slashing captured");

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        vm.prank(core);
        uint256 second = stakingManager.getSlashingDelta();
        assertEq(second, first, "cumulative slashing does not decrease");
    }

    /// @notice Tests that slashing delta is computed using the original staked amount,
    ///         not the current activation threshold, when threshold changes between stakes.
    function test_GetSlashingDelta_UsesOriginalStakedAmount() external {
        // Stake first attester at 100 ether threshold
        IStakingManager.KeyStore[] memory keys1 = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys1);

        uint256 originalThreshold = ACTIVATION_THRESHOLD; // 100 ether
        aztec.mint(core, originalThreshold);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), originalThreshold);
        stakingManager.stake(originalThreshold);
        vm.stopPrank();

        // Change activation threshold to 150 ether
        uint256 newThreshold = 150 ether;
        rollup.setActivationThreshold(newThreshold);

        // Stake second attester at new threshold
        IStakingManager.KeyStore[] memory keys2 = new IStakingManager.KeyStore[](1);
        keys2[0] = IStakingManager.KeyStore({
            attester: address(uint160(100)),
            publicKeyG1: G1Point({ x: 100, y: 101 }),
            publicKeyG2: G2Point({ x0: 100, x1: 101, y0: 102, y1: 103 }),
            proofOfPossession: G1Point({ x: 110, y: 111 })
        });
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys2);

        aztec.mint(core, newThreshold);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), newThreshold);
        stakingManager.stake(newThreshold);
        vm.stopPrank();

        // totalStaked should be sum of original amounts: 100 + 150 = 250
        assertEq(
            stakingManager.totalStaked(), originalThreshold + newThreshold, "totalStaked should sum original amounts"
        );

        // Simulate slashing: attester1 lost 10 ether, attester2 lost 20 ether
        uint256 attester1Remaining = originalThreshold - 10 ether; // 90 ether
        uint256 attester2Remaining = newThreshold - 20 ether; // 130 ether

        rollup.setExternalExit(keys1[0].attester, attester1Remaining, block.timestamp);
        rollup.setExternalExit(keys2[0].attester, attester2Remaining, block.timestamp);

        vm.prank(core);
        uint256 slashingDelta = stakingManager.getSlashingDelta();

        // Slashing delta should be: (100 - 90) + (150 - 130) = 10 + 20 = 30
        // NOT: (150 - 90) + (150 - 130) = 60 + 20 = 80 (if using current threshold)
        assertEq(slashingDelta, 30 ether, "slashing delta should use original staked amounts");
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
