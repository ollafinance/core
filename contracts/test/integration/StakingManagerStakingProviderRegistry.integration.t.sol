// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MockRewardsCollector } from "src/core/mocks/MockRewardsCollector.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

/// @title StakingManagerStakingProviderRegistryIntegrationTest
/// @notice Integration tests for StakingManager and StakingProviderRegistry working together.
/// @dev Tests full end-to-end flows across both contracts.
contract StakingManagerStakingProviderRegistryIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant ACTIVATION_THRESHOLD = 100 ether;
    bytes32 internal constant STAKING_PROVIDER_ADMIN_ROLE = keccak256("STAKING_PROVIDER_ADMIN_ROLE");

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    MockAztec internal aztec;
    MockAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;
    MockRewardsCollector internal rewardsCollector;

    address internal core;
    address internal providerAdmin;
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
        rewardsCollector = new MockRewardsCollector(IERC20(address(aztec)), core);

        // Deploy StakingProviderRegistry first
        StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));

        // Deploy StakingManager
        StakingManager implementation = new StakingManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        stakingManager = StakingManager(address(proxy));

        // Initialize StakingProviderRegistry with staking manager address
        stakingProviderRegistry.initialize(
            address(stakingManager),
            providerAdmin,
            providerAdmin, // rewardsRecipient same as admin for simplicity
            defaultAdmin
        );

        // Initialize StakingManager
        stakingManager.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsCollector),
            core,
            address(stakingProviderRegistry),
            defaultAdmin
        );
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    uint256 internal _keyOffset;

    function _createMockKeys(uint256 count) internal returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            uint256 keyId = _keyOffset + i + 1;
            keys[i] = IStakingManager.KeyStore({
                attester: address(uint160(keyId)),
                publicKeyG1: G1Point({ x: keyId, y: keyId + 1 }),
                publicKeyG2: G2Point({ x0: keyId, x1: keyId + 1, y0: keyId + 2, y1: keyId + 3 }),
                proofOfPossession: G1Point({ x: keyId + 10, y: keyId + 11 })
            });
        }
        _keyOffset += count;
        return keys;
    }

    function _addKeys(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);
    }

    function _stake(uint256 amount) internal {
        aztec.mint(core, amount);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), amount);
        stakingManager.stake(amount);
        vm.stopPrank();
    }

    function _setupStakedAttesters(uint256 count) internal returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        _addKeysFromMemory(keys);
        _stake(ACTIVATION_THRESHOLD * count);
        return keys;
    }

    function _addKeysFromMemory(IStakingManager.KeyStore[] memory keys) internal {
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);
    }

    /*//////////////////////////////////////////////////////////////
                     FULL STAKE FLOW INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullStakeFlow_AddKeysThenStake() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(3);

        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        assertEq(stakingProviderRegistry.getQueueLength(), 3);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * 3;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);

        vm.expectEmit(true, true, true, true);
        emit StakedWithProvider(keys[0].attester, ACTIVATION_THRESHOLD);

        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        assertEq(stakingManager.getActivatedAttesterCount(), 3);
        assertEq(stakingProviderRegistry.getQueueLength(), 0);
        assertEq(aztec.balanceOf(address(rollup)), stakeAmount);
    }

    function test_Stake_ExhaustsQueuePartially() external {
        // Add 5 keys, try to stake for 10
        _addKeys(5);

        uint256 requestedAmount = ACTIVATION_THRESHOLD * 10;
        uint256 expectedStakedAmount = ACTIVATION_THRESHOLD * 5;
        aztec.mint(core, requestedAmount);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), requestedAmount);
        stakingManager.stake(requestedAmount);
        vm.stopPrank();

        // Only 5 attesters should be staked, remaining funds stay with core
        assertEq(stakingManager.getActivatedAttesterCount(), 5);
        assertEq(stakingProviderRegistry.getQueueLength(), 0);
        assertEq(aztec.balanceOf(core), coreBalanceBefore - expectedStakedAmount);
    }

    function test_Stake_MultipleBatches() external {
        // First batch: add 2 keys, stake for 2
        _addKeys(2);
        _stake(ACTIVATION_THRESHOLD * 2);

        assertEq(stakingManager.getActivatedAttesterCount(), 2);
        assertEq(stakingProviderRegistry.getQueueLength(), 0);

        // Second batch: add 3 more keys, stake for 3
        _addKeys(3);
        _stake(ACTIVATION_THRESHOLD * 3);

        assertEq(stakingManager.getActivatedAttesterCount(), 5);
        assertEq(stakingProviderRegistry.getQueueLength(), 0);
    }

    function test_StakeWithRegistryUpdatesDuringStaking() external {
        // Add 2 keys initially
        _addKeys(2);

        // Stake for 1 attester
        _stake(ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        assertEq(stakingProviderRegistry.getQueueLength(), 1);

        // Provider adds more keys while staking is ongoing
        _addKeys(3);
        assertEq(stakingProviderRegistry.getQueueLength(), 4);

        // Stake for remaining capacity
        _stake(ACTIVATION_THRESHOLD * 4);
        assertEq(stakingManager.getActivatedAttesterCount(), 5);
        assertEq(stakingProviderRegistry.getQueueLength(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                     FULL UNSTAKE FLOW INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullUnstakeFlow_StakeThenUnstakeThenClaim() external {
        _setupStakedAttesters(3);

        // Refresh cached state so view functions work
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();
        assertEq(stateBefore.stakedAmount, ACTIVATION_THRESHOLD * 3);

        // Initiate unstake for 2 attesters
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        assertEq(stakingManager.getPendingUnstakeCount(), 2);

        // Finalize exits first (permissionless), then claim unstaked funds
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        stakingManager.finalizeExits();
        vm.prank(core);
        (uint256 claimed,,) = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD * 2);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + claimed);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_UnstakeAndRestake() external {
        _setupStakedAttesters(3);

        // Unstake all
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 3);

        // Finalize exits first (permissionless), then claim funds
        stakingManager.finalizeExits();
        vm.prank(core);
        stakingManager.getUnstakedFunds();

        // Keys were consumed - need to add new keys
        _addKeys(2);

        // Restake with new keys
        _stake(ACTIVATION_THRESHOLD * 2);

        assertEq(stakingManager.getActivatedAttesterCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                     REWARDS FLOW INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HarvestRewardsFlow() external {
        _setupStakedAttesters(2);

        uint256 rewardAmount = 10 ether;
        aztec.mint(address(rollup), rewardAmount);
        rollup.setRewards(address(rewardsCollector), rewardAmount);

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, rewardAmount);
    }

    function test_ProviderConfigUpdate_AffectsRewardsRecipient() external {
        _setupStakedAttesters(2);

        address newRewardsRecipient = makeAddr("newRewardsRecipient");

        // Provider updates rewards recipient
        vm.prank(providerAdmin);
        stakingProviderRegistry.setProviderRewardsRecipient(newRewardsRecipient);

        IStakingManager.ProviderConfig memory config = stakingManager.getProviderConfig();
        assertEq(config.rewardsRecipient, newRewardsRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                     CLEAN ACTIVATED ATTESTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CleanActivatedAttesters_ExternalExits() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(3);

        // Simulate external exits for 2 attesters
        for (uint256 i; i < 2; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD, block.timestamp);
        }

        // computeAttesterState() syncs Active→Exiting for externally exited attesters
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        assertEq(stakingManager.getPendingUnstakeCount(), 2);

        // Finalize exits first (permissionless), then claim the externally exited funds
        uint256 coreBalanceBefore = aztec.balanceOf(core);
        stakingManager.finalizeExits();
        vm.prank(core);
        (uint256 claimed,,) = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD * 2);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + claimed);
    }

    /*//////////////////////////////////////////////////////////////
                     ACCESS CONTROL INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AccessControl_StakingManagerOnlyDequeues() external {
        _addKeys(3);

        // Provider admin cannot dequeue directly
        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingProviderRegistry.StakingProviderRegistry__UnauthorizedStakingManager.selector, providerAdmin
            )
        );
        vm.prank(providerAdmin);
        stakingProviderRegistry.getAttesterKeystore();

        // Only staking manager can dequeue (through stake)
        _stake(ACTIVATION_THRESHOLD);
        assertEq(stakingProviderRegistry.getQueueLength(), 2);
    }

    function test_AccessControl_ProviderAdminManagesKeys() external {
        // Non-provider-admin cannot add keys
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, STAKING_PROVIDER_ADMIN_ROLE
            )
        );
        vm.prank(alice);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        stakingProviderRegistry.addKeysToProvider(keys);

        // Provider admin can add keys
        _addKeys(3);
        assertEq(stakingProviderRegistry.getQueueLength(), 3);
    }

    /*//////////////////////////////////////////////////////////////
                     STATE CONSISTENCY INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_StakingState_AggregatesAcrossContracts() external {
        _setupStakedAttesters(3);

        // Unstake 2 to move them to pending
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        // Refresh cached state so view functions reflect current attester state
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        // Query staking state from StakingManager
        IStakingManager.StakingState memory state = stakingManager.getStakingState();

        // stakedAmount includes all Active + Exiting attesters (3 × 100 ether)
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD * 3, "stakedAmount includes exiting attesters");
        // The 2 unstaked attesters have exitable exits (mock rollup auto-finalizes)
        assertEq(state.withdrawableAmount, ACTIVATION_THRESHOLD * 2, "2 exits ready to claim");
    }

    function test_ProviderConfig_DelegatesToRegistry() external view {
        // Query through StakingManager delegates to registry
        IStakingManager.ProviderConfig memory config = stakingManager.getProviderConfig();

        // Direct query from registry
        IStakingManager.ProviderConfig memory directConfig = stakingProviderRegistry.getStakingProviderConfig();

        assertEq(config.admin, directConfig.admin);
        assertEq(config.rewardsRecipient, directConfig.rewardsRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                     CROSS-CONTRACT EVENT VERIFICATION
    //////////////////////////////////////////////////////////////*/

    function test_CrossContractEvents_StakeFlow() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        // Events from StakingProviderRegistry
        vm.expectEmit(true, true, true, true, address(stakingProviderRegistry));
        emit KeysAddedToProvider(_extractAttesters(keys));

        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD * 2);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD * 2);

        // Events from StakingManager
        for (uint256 i; i < 2; ++i) {
            vm.expectEmit(true, true, true, true, address(stakingManager));
            emit StakedWithProvider(keys[i].attester, ACTIVATION_THRESHOLD);
        }

        stakingManager.stake(ACTIVATION_THRESHOLD * 2);
        vm.stopPrank();
    }

    function test_CrossContractEvents_UnstakeFlow() external {
        IStakingManager.KeyStore[] memory keys = _setupStakedAttesters(1);

        vm.prank(core);
        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit UnstakeInitiated(keys[0].attester, ACTIVATION_THRESHOLD);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // finalizeExits() is permissionless and emits UnstakeFinalized
        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit UnstakeFinalized(keys[0].attester, ACTIVATION_THRESHOLD);
        stakingManager.finalizeExits();

        // getUnstakedFunds() sweeps balance to core and emits UnstakedFundsClaimed
        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit UnstakedFundsClaimed(ACTIVATION_THRESHOLD);
        vm.prank(core);
        stakingManager.getUnstakedFunds();
    }

    /*//////////////////////////////////////////////////////////////
                          COMPLEX SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ComplexScenario_MultipleStakeUnstakeCycles() external {
        // Cycle 1: Add 5, stake 3, unstake 2
        _addKeys(5);
        _stake(ACTIVATION_THRESHOLD * 3);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        assertEq(stakingManager.getActivatedAttesterCount(), 1);
        assertEq(stakingManager.getPendingUnstakeCount(), 2);
        assertEq(stakingProviderRegistry.getQueueLength(), 2);

        // Finalize exits first (permissionless), then claim unstaked funds
        stakingManager.finalizeExits();
        vm.prank(core);
        stakingManager.getUnstakedFunds();

        // Cycle 2: Add 2 more, stake remaining 4
        _addKeys(2);
        _stake(ACTIVATION_THRESHOLD * 4);

        assertEq(stakingManager.getActivatedAttesterCount(), 5);
        assertEq(stakingProviderRegistry.getQueueLength(), 0);

        // Cycle 3: Unstake all
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 5);

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), 5);
    }

    function test_ComplexScenario_KeyQueueWithDrip() external {
        // Add 10 keys
        _addKeys(10);

        // Drip 3 keys (remove without staking)
        vm.prank(providerAdmin);
        stakingProviderRegistry.dripQueue(3);

        assertEq(stakingProviderRegistry.getQueueLength(), 7);

        // Stake for 5 attesters
        _stake(ACTIVATION_THRESHOLD * 5);

        assertEq(stakingManager.getActivatedAttesterCount(), 5);
        assertEq(stakingProviderRegistry.getQueueLength(), 2);

        // Add 5 more keys
        _addKeys(5);
        assertEq(stakingProviderRegistry.getQueueLength(), 7);

        // Stake remaining
        _stake(ACTIVATION_THRESHOLD * 7);

        assertEq(stakingManager.getActivatedAttesterCount(), 12);
        assertEq(stakingProviderRegistry.getQueueLength(), 0);
    }

    function test_ComplexScenario_ProviderUpdatesDuringActiveStaking() external {
        _setupStakedAttesters(5);

        // Update rewards recipient while staking is active
        address newRewardsRecipient = makeAddr("newRewardsRecipient");
        vm.prank(providerAdmin);
        stakingProviderRegistry.setProviderRewardsRecipient(newRewardsRecipient);

        // Continue staking operations
        _addKeys(3);
        _stake(ACTIVATION_THRESHOLD * 3);

        assertEq(stakingManager.getActivatedAttesterCount(), 8);

        IStakingManager.ProviderConfig memory config = stakingManager.getProviderConfig();
        assertEq(config.rewardsRecipient, newRewardsRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _extractAttesters(IStakingManager.KeyStore[] memory keys) internal pure returns (address[] memory) {
        address[] memory attesters = new address[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            attesters[i] = keys[i].attester;
        }
        return attesters;
    }
}
