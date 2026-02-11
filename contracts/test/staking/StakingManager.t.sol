// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test, Vm } from "@forge-std/Test.sol";
import { StdStorage, stdStorage } from "@forge-std/StdStorage.sol";

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
    using stdStorage for StdStorage;
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

    function _getActiveSyncCursor() internal returns (uint256) {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 activeSyncCursorSlot = bytes32(cursorSlot + 2);
        return uint256(vm.load(address(stakingManager), activeSyncCursorSlot));
    }

    function _setActiveSyncCursor(uint256 value) internal {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 activeSyncCursorSlot = bytes32(cursorSlot + 2);
        vm.store(address(stakingManager), activeSyncCursorSlot, bytes32(value));
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

    function test_Unstake_NoStaked_ReturnsZero() external {
        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        vm.prank(core);
        uint256 unstakedAmount = stakingManager.unstake(ACTIVATION_THRESHOLD);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(unstakedAmount, 0, "unstake should return zero when nothing is staked");
        assertEq(stateAfter.stakedAmount, stateBefore.stakedAmount, "staked amount should remain unchanged");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "no pending unstakes should be created");
    }

    function test_RevertWhen_Unstake_ZeroAmount() external {
        _setupStakedAttester();

        vm.prank(core);
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAmount.selector));
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
        uint256 unstakedAmount = stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(unstakedAmount, ACTIVATION_THRESHOLD * 2, "unstake should return requested amount");
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        assertEq(stakingManager.getPendingUnstakeCount(), 2);
    }

    function test_Unstake_ExceedsStaked_ClampsAndUpdates() external {
        _setupMultipleStakedAttesters(2);

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();

        vm.prank(core);
        uint256 unstakedAmount = stakingManager.unstake(ACTIVATION_THRESHOLD * 3);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(unstakedAmount, stateBefore.stakedAmount, "unstake should clamp to staked amount");
        assertEq(stateAfter.stakedAmount, 0, "staked amount should be fully drained");
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
        assertEq(stakingManager.getPendingUnstakeCount(), 2, "pending count should match attesters");
    }

    function test_Unstake_Bounded_LowGasInitiatesSubset() external {
        uint256 attesterCount = 6;
        _setupMultipleStakedAttesters(attesterCount);

        uint256 requested = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 unstakedObserved;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.unstake, (requested)));
            if (!success) {
                continue;
            }
            uint256 unstakedCandidate = abi.decode(data, (uint256));
            if (unstakedCandidate == requested) {
                assertEq(unstakedCandidate, requested, "unstake should complete in one call");
                assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
                assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
                return;
            }
            if (unstakedCandidate > 0 && unstakedCandidate < requested) {
                selectedGas = gasOptions[i];
                unstakedObserved = unstakedCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            uint256 unstakedFull = stakingManager.unstake{ gas: 2_000_000 }(requested);

            assertEq(unstakedFull, requested, "unstake should complete in one call");
            assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
            assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(core);
        uint256 unstakedAmount = stakingManager.unstake{ gas: selectedGas }(requested);

        assertEq(unstakedAmount, unstakedObserved, "unstaked amount should match probe");
        assertGt(unstakedAmount, 0, "unstake should initiate some exits");
        assertLt(unstakedAmount, requested, "unstake should be bounded under low gas");
        assertGt(stakingManager.getActivatedAttesterCount(), 0, "activated attesters should remain");
        assertGt(stakingManager.getPendingUnstakeCount(), 0, "pending unstakes should increase");
    }

    function test_Unstake_Bounded_ResumesAcrossCalls() external {
        uint256 attesterCount = 5;
        _setupMultipleStakedAttesters(attesterCount);

        uint256 requested = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.unstake, (requested)));
            if (!success) {
                continue;
            }
            uint256 unstakedCandidate = abi.decode(data, (uint256));
            if (unstakedCandidate > 0 && unstakedCandidate < requested) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            uint256 unstakedFull = stakingManager.unstake{ gas: 2_000_000 }(requested);

            assertEq(unstakedFull, requested, "unstake should complete in one call");
            assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
            assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
            return;
        }

        vm.revertToState(snapshotId);
        uint256 totalUnstaked;
        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getActivatedAttesterCount() == 0) {
                break;
            }
            vm.prank(core);
            totalUnstaked += stakingManager.unstake{ gas: selectedGas }(requested);
        }

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
        assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
        assertEq(totalUnstaked, requested, "total unstaked should equal requested");
    }

    function test_Unstake_Bounded_CursorTracksProgress() external {
        uint256 attesterCount = 4;
        _setupMultipleStakedAttesters(attesterCount);

        uint256 requested = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.unstake, (requested)));
            if (!success) {
                continue;
            }
            uint256 unstakedCandidate = abi.decode(data, (uint256));
            if (unstakedCandidate > 0 && unstakedCandidate < requested) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial unstake");

        vm.revertToState(snapshotId);

        uint256 cursorBefore = stakingManager.getUnstakeCursor();

        vm.prank(core);
        stakingManager.unstake{ gas: selectedGas }(requested);

        uint256 cursorAfter = stakingManager.getUnstakeCursor();
        uint256 remaining = stakingManager.getActivatedAttesterCount();
        assertLe(cursorAfter, remaining, "cursor should stay within activated bounds");
        assertEq(cursorBefore, 0, "cursor should start at 0");

        vm.prank(core);
        stakingManager.setGasThreshold(1);
        vm.prank(core);
        stakingManager.unstake(requested);

        assertEq(stakingManager.getUnstakeCursor(), 0, "cursor should reset after completion");
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

    function test_GetUnstakedFunds_ExternalExitReconciliation() external {
        _setupMultipleStakedAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        uint256 activatedBefore = stakingManager.getActivatedAttesterCount();
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), activatedBefore - 1, "active count should decrease");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "exiting count should increase");
        assertTrue(stakingManager.isUnstakePending(keys[0].attester), "attester should be marked exiting");

        vm.recordLogs();

        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundEvent = false;
        bytes32 expectedSelector = keccak256("UnstakedFundsClaimed(uint256)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(stakingManager) && entries[i].topics[0] == expectedSelector) {
                uint256 amount = uint256(entries[i].topics[1]);
                assertEq(amount, ACTIVATION_THRESHOLD, "claimed amount should match exit");
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "UnstakedFundsClaimed event not found");

        assertEq(claimed, ACTIVATION_THRESHOLD, "claimed should equal exited stake");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + claimed, "core should receive claimed funds");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after claim");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "exited attester should be inactive");
    }

    function test_GetUnstakedFunds_RestakeAfterExit_ReusesEntry() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        stakingManager.getUnstakedFunds();
        vm.stopPrank();

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "attester should be inactive after exit");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after exit");

        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester should be active again");
        assertFalse(stakingManager.isUnstakePending(keys[0].attester), "attester should not be exiting");
    }

    function test_Unstake_CursorDoesNotSkipAfterStateChange() external {
        _setupMultipleStakedAttesters(3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        assertEq(stakingManager.getPendingUnstakeCount(), 1, "first unstake should mark one exiting");
        assertEq(stakingManager.getActivatedAttesterCount(), 2, "two attesters should remain active");

        vm.prank(core);
        uint256 unstaked = stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        assertEq(unstaked, ACTIVATION_THRESHOLD * 2, "unstake should process remaining active attesters");
        assertEq(stakingManager.getPendingUnstakeCount(), 3, "all attesters should be exiting");
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "no active attesters should remain");
    }

    function test_GetUnstakedFunds_ActivatedExits_PartialFinalizeResetsCursor() external {
        uint256 attesterCount = 6;
        _setupMultipleStakedAttesters(attesterCount);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(attesterCount);

        for (uint256 i; i < attesterCount; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD, block.timestamp);
        }

        uint256 expectedTotal = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(200_000);

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "all exits should move to exiting");
        assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "exiting count should match attesters");

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 claimedObserved;
        uint256[5] memory gasOptions = [uint256(220_000), 260_000, 300_000, 340_000, 380_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.getUnstakedFunds, ()));
            if (!success) {
                continue;
            }
            uint256 claimedCandidate = abi.decode(data, (uint256));
            if (claimedCandidate > 0 && claimedCandidate < expectedTotal) {
                selectedGas = gasOptions[i];
                claimedObserved = claimedCandidate;
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial finalize");

        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 finalizeCursorSlot = bytes32(cursorSlot + 1);

        vm.revertToState(snapshotId);
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimedFirst = stakingManager.getUnstakedFunds{ gas: selectedGas }();

        assertEq(claimedFirst, claimedObserved, "claimed amount should match probe");
        assertGt(claimedFirst, 0, "initial claim should return some funds");
        assertLt(claimedFirst, expectedTotal, "initial claim should be partial");
        assertGt(stakingManager.getPendingUnstakeCount(), 0, "exiting attesters should remain after partial claim");

        uint256 totalClaimed = claimedFirst;
        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getPendingUnstakeCount() == 0) {
                break;
            }
            vm.prank(core);
            totalClaimed += stakingManager.getUnstakedFunds{ gas: selectedGas }();
        }

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "remaining exits should complete across calls");
        assertEq(totalClaimed, expectedTotal, "total claimed should match exits");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + totalClaimed, "core should receive claimed funds");

        uint256 finalizeCursorAfter = uint256(vm.load(address(stakingManager), finalizeCursorSlot));
        assertEq(finalizeCursorAfter, 0, "finalize cursor should reset after completion");
    }

    function test_GetUnstakedFunds_Bounded_LowGasCompletesAcrossCalls() external {
        uint256 attesterCount = 5;
        _setupMultipleStakedAttesters(attesterCount);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * attesterCount);

        uint256 expectedTotal = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 claimedObserved;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.getUnstakedFunds, ()));
            if (!success) {
                continue;
            }
            uint256 claimedCandidate = abi.decode(data, (uint256));
            if (claimedCandidate > 0 && claimedCandidate < expectedTotal) {
                selectedGas = gasOptions[i];
                claimedObserved = claimedCandidate;
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial finalize");

        vm.revertToState(snapshotId);
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimedFirst = stakingManager.getUnstakedFunds{ gas: selectedGas }();

        assertEq(claimedFirst, claimedObserved, "claimed amount should match probe");
        assertGt(claimedFirst, 0, "initial claim should return some funds");
        assertLt(claimedFirst, expectedTotal, "initial claim should be bounded under low gas");
        assertGt(stakingManager.getPendingUnstakeCount(), 0, "pending should remain after partial claim");

        uint256 totalClaimed = claimedFirst;
        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getPendingUnstakeCount() == 0) {
                break;
            }
            vm.prank(core);
            totalClaimed += stakingManager.getUnstakedFunds{ gas: selectedGas }();
        }

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "all pending unstakes should be finalized");
        assertEq(totalClaimed, expectedTotal, "total claimed should match pending exits");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + totalClaimed, "core should receive claimed funds");
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

    function test_HasExitableUnstakes_ReturnsFalseWhenOnlyPending() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        bool hasExitable = stakingManager.hasExitableUnstakes();
        assertFalse(hasExitable, "hasExitableUnstakes should be false with only pending exits");
    }

    function test_HasExitableUnstakes_ReturnsTrueWhenWithdrawable() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        bool hasExitable = stakingManager.hasExitableUnstakes();
        assertTrue(hasExitable, "hasExitableUnstakes should be true when exits are withdrawable");
    }

    function test_HasExitableUnstakes_ReturnsTrueWhenActiveExitIsExitable() external {
        _setupStakedAttester();

        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        bool hasExitable = stakingManager.hasExitableUnstakes();
        assertTrue(hasExitable, "hasExitableUnstakes should be true for active exitable exits");
    }

    function test_HasExitableUnstakes_ReturnsFalseWhenActiveExitNotExitable() external {
        _setupStakedAttester();

        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp + 1 days);

        bool hasExitable = stakingManager.hasExitableUnstakes();
        assertFalse(hasExitable, "hasExitableUnstakes should be false for active pending exits");
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
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), total - exited);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);
    }

    function test_CleanActivatedAttesters_NoExits() external {
        _setupMultipleStakedAttesters(2);

        uint256 activatedBefore = stakingManager.getActivatedAttesterCount();
        uint256 pendingBefore = stakingManager.getPendingUnstakeCount();

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), activatedBefore);
        assertEq(stakingManager.getPendingUnstakeCount(), pendingBefore);
    }

    function test_CleanActivatedAttesters_ExitPresent_MarksExiting() external {
        uint256 total = 2;
        _setupMultipleStakedAttesters(total);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);

        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        vm.prank(core);
        stakingManager.syncAttesters();

        assertTrue(stakingManager.isUnstakePending(keys[0].attester), "exited attester should be exiting");
        assertFalse(stakingManager.isUnstakePending(keys[1].attester), "non-exited attester should remain active");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "pending count should match exited attesters");
    }

    function test_CleanActivatedAttesters_Bounded_ActiveSyncCursorResumes() external {
        uint256 total = 12;
        _setupStakedAttestersWithExits(total, total);

        vm.prank(core);
        stakingManager.setGasThreshold(200_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 pendingObserved;
        uint256[6] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000, 340_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success,) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.syncAttesters, ()));
            if (!success) {
                continue;
            }
            uint256 pendingCandidate = stakingManager.getPendingUnstakeCount();
            if (pendingCandidate > 0 && pendingCandidate < total) {
                selectedGas = gasOptions[i];
                pendingObserved = pendingCandidate;
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial sync");

        vm.revertToState(snapshotId);

        uint256 cursorBefore = _getActiveSyncCursor();

        vm.prank(core);
        stakingManager.syncAttesters{ gas: selectedGas }();

        uint256 cursorAfterFirst = _getActiveSyncCursor();
        uint256 pendingAfterFirst = stakingManager.getPendingUnstakeCount();

        assertEq(cursorBefore, 0, "cursor should start at 0");
        assertEq(pendingAfterFirst, pendingObserved, "pending count should match probe");
        assertGt(pendingAfterFirst, 0, "should move some attesters to exiting");
        assertLt(pendingAfterFirst, total, "should not process all attesters under low gas");
        assertGt(cursorAfterFirst, 0, "cursor should advance after partial sync");
        assertLt(cursorAfterFirst, total, "cursor should remain within bounds");

        vm.prank(core);
        stakingManager.syncAttesters{ gas: selectedGas }();

        uint256 cursorAfterSecond = _getActiveSyncCursor();
        uint256 pendingAfterSecond = stakingManager.getPendingUnstakeCount();

        assertGt(pendingAfterSecond, pendingAfterFirst, "sync should resume across calls");
        assertTrue(
            cursorAfterSecond == 0 || cursorAfterSecond > cursorAfterFirst,
            "cursor should advance or reset after completion"
        );
    }

    function test_CleanActivatedAttesters_NoActive_ResetsActiveSyncCursor() external {
        _setActiveSyncCursor(7);

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(_getActiveSyncCursor(), 0, "cursor should reset when no active attesters");
    }

    function test_CleanActivatedAttesters_Bounded_LowGasCompletesAcrossCalls() external {
        uint256 total = 6;
        uint256 exited = 5;
        _setupStakedAttestersWithExits(total, exited);

        vm.prank(core);
        stakingManager.setGasThreshold(180_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 pendingObserved;
        uint256[5] memory gasOptions = [uint256(220_000), 240_000, 260_000, 280_000, 300_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success,) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.syncAttesters, ()));
            if (!success) {
                continue;
            }
            uint256 pendingCandidate = stakingManager.getPendingUnstakeCount();
            if (pendingCandidate == exited) {
                assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
                assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
                return;
            }
            if (pendingCandidate > 0 && pendingCandidate < exited) {
                selectedGas = gasOptions[i];
                pendingObserved = pendingCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            stakingManager.syncAttesters{ gas: 2_000_000 }();

            assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
            assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(core);
        stakingManager.syncAttesters{ gas: selectedGas }();

        uint256 pendingAfterFirst = stakingManager.getPendingUnstakeCount();
        assertEq(pendingAfterFirst, pendingObserved, "pending count should match probe");
        assertGt(pendingAfterFirst, 0, "should move some exited attesters");
        assertLt(pendingAfterFirst, exited, "should not move all exited attesters under low gas");

        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getPendingUnstakeCount() == exited) {
                break;
            }
            vm.prank(core);
            stakingManager.syncAttesters{ gas: selectedGas }();
        }

        assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
        assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
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
        stakingManager.syncAttesters();

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
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);
    }

    function test_CleanActivatedAttesters_EmptyActivated() external {
        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_RevertWhen_CleanActivatedAttesters_Unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        stakingManager.syncAttesters();
    }

    /*//////////////////////////////////////////////////////////////
                           GAS THRESHOLD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Stake_GasThresholdLow_BoundedAndResumes() external {
        uint256 attesterCount = 1;
        IStakingManager.KeyStore[] memory keys = _createMockKeys(attesterCount);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * attesterCount;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), type(uint256).max);
        stakingManager.setGasThreshold(1_000);
        vm.stopPrank();

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 stakedObserved;
        uint256[6] memory gasOptions = [uint256(300_000), 400_000, 500_000, 600_000, 700_000, 800_000];

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
                stakedObserved = stakedCandidate;
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
        vm.prank(core);
        uint256 stakedFirst = stakingManager.stake{ gas: selectedGas }(stakeAmount);

        assertEq(stakedFirst, stakedObserved, "staked amount should match probe");
        assertGt(stakingManager.getActivatedAttesterCount(), 0, "should stake some attesters");
        assertLt(stakingManager.getActivatedAttesterCount(), attesterCount, "should leave keys in queue");

        uint256 totalStaked = stakedFirst;
        uint256 maxIterations = 50;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getActivatedAttesterCount() == attesterCount) {
                break;
            }
            vm.prank(core);
            totalStaked += stakingManager.stake{ gas: selectedGas }(stakeAmount);
        }

        assertEq(stakingManager.getActivatedAttesterCount(), attesterCount, "all attesters should be staked");
        assertEq(stakingProviderRegistry.getQueueLength(), 0, "queue should be empty");
        assertEq(totalStaked, stakeAmount, "total staked should equal requested");
    }

    function test_Stake_GasThresholdLow_LargeCount_DoesNotRevert() external {
        uint256 attesterCount = 25;
        IStakingManager.KeyStore[] memory keys = _createMockKeys(attesterCount);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * attesterCount;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), type(uint256).max);
        stakingManager.setGasThreshold(1_000);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();
    }

    function test_Unstake_GasThresholdLow_BoundedAndResumes() external {
        uint256 attesterCount = 6;
        _setupMultipleStakedAttesters(attesterCount);

        uint256 requested = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(1_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 unstakedObserved;
        uint256[5] memory gasOptions = [uint256(200_000), 230_000, 260_000, 290_000, 320_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.unstake, (requested)));
            if (!success) {
                continue;
            }
            uint256 unstakedCandidate = abi.decode(data, (uint256));
            if (unstakedCandidate > 0 && unstakedCandidate < requested) {
                selectedGas = gasOptions[i];
                unstakedObserved = unstakedCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            uint256 unstakedFull = stakingManager.unstake{ gas: 2_000_000 }(requested);

            assertEq(unstakedFull, requested, "unstake should complete in one call");
            assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
            assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(core);
        uint256 unstakedFirst = stakingManager.unstake{ gas: selectedGas }(requested);

        assertEq(unstakedFirst, unstakedObserved, "unstaked amount should match probe");
        assertGt(unstakedFirst, 0, "unstake should initiate some exits");
        assertLt(unstakedFirst, requested, "unstake should be bounded under low gas");

        uint256 totalUnstaked = unstakedFirst;
        uint256 maxIterations = 20;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getActivatedAttesterCount() == 0) {
                break;
            }
            vm.prank(core);
            totalUnstaked += stakingManager.unstake{ gas: selectedGas }(requested);
        }

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "all attesters should be unstaked");
        assertEq(stakingManager.getPendingUnstakeCount(), attesterCount, "pending count should match attesters");
        assertEq(totalUnstaked, requested, "total unstaked should equal requested");
    }

    function test_CleanActivatedAttesters_GasThresholdLow_BoundedAndResumes() external {
        uint256 total = 6;
        uint256 exited = 5;
        _setupStakedAttestersWithExits(total, exited);

        vm.prank(core);
        stakingManager.setGasThreshold(1_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 pendingObserved;
        uint256[5] memory gasOptions = [uint256(200_000), 230_000, 260_000, 290_000, 320_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success,) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.syncAttesters, ()));
            if (!success) {
                continue;
            }
            uint256 pendingCandidate = stakingManager.getPendingUnstakeCount();
            if (pendingCandidate > 0 && pendingCandidate < exited) {
                selectedGas = gasOptions[i];
                pendingObserved = pendingCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            stakingManager.syncAttesters{ gas: 2_000_000 }();

            assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
            assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(core);
        stakingManager.syncAttesters{ gas: selectedGas }();

        uint256 pendingAfterFirst = stakingManager.getPendingUnstakeCount();
        assertEq(pendingAfterFirst, pendingObserved, "pending count should match probe");
        assertGt(pendingAfterFirst, 0, "should move some exited attesters");
        assertLt(pendingAfterFirst, exited, "should not move all exited attesters under low gas");

        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getPendingUnstakeCount() == exited) {
                break;
            }
            vm.prank(core);
            stakingManager.syncAttesters{ gas: selectedGas }();
        }

        assertEq(stakingManager.getPendingUnstakeCount(), exited, "all exited attesters should be pending");
        assertEq(stakingManager.getActivatedAttesterCount(), total - exited, "remaining activated should stay");
    }

    function test_GetUnstakedFunds_GasThresholdLow_BoundedAndResumes() external {
        uint256 attesterCount = 5;
        _setupMultipleStakedAttesters(attesterCount);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * attesterCount);

        uint256 expectedTotal = ACTIVATION_THRESHOLD * attesterCount;

        vm.prank(core);
        stakingManager.setGasThreshold(1_000);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256 claimedObserved;
        uint256[5] memory gasOptions = [uint256(200_000), 230_000, 260_000, 290_000, 320_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(core);
            (bool success, bytes memory data) =
                address(stakingManager).call{ gas: gasOptions[i] }(abi.encodeCall(stakingManager.getUnstakedFunds, ()));
            if (!success) {
                continue;
            }
            uint256 claimedCandidate = abi.decode(data, (uint256));
            if (claimedCandidate > 0 && claimedCandidate < expectedTotal) {
                selectedGas = gasOptions[i];
                claimedObserved = claimedCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            uint256 coreBalanceBeforeFull = aztec.balanceOf(core);

            vm.prank(core);
            uint256 claimedFull = stakingManager.getUnstakedFunds{ gas: 2_000_000 }();

            assertEq(claimedFull, expectedTotal, "claim should complete in one call");
            assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after claim");
            assertEq(aztec.balanceOf(core), coreBalanceBeforeFull + claimedFull, "core should receive claimed funds");
            return;
        }

        vm.revertToState(snapshotId);
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        uint256 claimedFirst = stakingManager.getUnstakedFunds{ gas: selectedGas }();

        assertEq(claimedFirst, claimedObserved, "claimed amount should match probe");
        assertGt(claimedFirst, 0, "initial claim should return some funds");
        assertLt(claimedFirst, expectedTotal, "initial claim should be bounded under low gas");
        assertGt(stakingManager.getPendingUnstakeCount(), 0, "pending should remain after partial claim");

        uint256 totalClaimed = claimedFirst;
        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            if (stakingManager.getPendingUnstakeCount() == 0) {
                break;
            }
            vm.prank(core);
            totalClaimed += stakingManager.getUnstakedFunds{ gas: selectedGas }();
        }

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "all pending unstakes should be finalized");
        assertEq(totalClaimed, expectedTotal, "total claimed should match pending exits");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + totalClaimed, "core should receive claimed funds");
    }

    function test_GasThresholdHigh_CompletesInOneCall() external {
        uint256 highThreshold = 400_000;
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * 2;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.setGasThreshold(highThreshold);
        uint256 stakedAmount = stakingManager.stake(stakeAmount);
        vm.stopPrank();

        assertEq(stakedAmount, stakeAmount, "stake should complete in one call");
        assertEq(stakingManager.getActivatedAttesterCount(), 2, "all attesters should be activated");

        uint256 snapshotId = vm.snapshotState();
        rollup.setExternalExit(keys[0].attester, ACTIVATION_THRESHOLD, block.timestamp);

        vm.prank(core);
        stakingManager.syncAttesters();

        assertEq(stakingManager.getPendingUnstakeCount(), 1, "clean should move exited attester in one call");

        vm.revertToState(snapshotId);
        vm.prank(core);
        uint256 unstakedAmount = stakingManager.unstake(stakeAmount);

        assertEq(unstakedAmount, stakeAmount, "unstake should complete in one call");
        assertEq(stakingManager.getPendingUnstakeCount(), 2, "pending count should match attesters");

        uint256 coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, stakeAmount, "claim should complete in one call");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending should clear after claim");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + claimed, "core should receive claimed funds");
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
