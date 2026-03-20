// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Initializable } from "@oz/proxy/utils/Initializable.sol";

import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

contract StakingProviderRegistryTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant STAKING_PROVIDER_ADMIN_ROLE = keccak256("STAKING_PROVIDER_ADMIN_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    StakingProviderRegistry internal registry;

    address internal stakingManager;
    address internal providerAdmin;
    address internal providerRewardsRecipient;
    address internal defaultAdmin;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProviderSet(address indexed admin, address indexed rewardsRecipient);
    event KeysAddedToProvider(address[] attesters);
    event QueueDripped(address indexed attester);

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        stakingManager = makeAddr("stakingManager");
        providerAdmin = makeAddr("providerAdmin");
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        defaultAdmin = makeAddr("defaultAdmin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        StakingProviderRegistry implementation = new StakingProviderRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        registry = StakingProviderRegistry(address(proxy));

        registry.initialize(stakingManager, providerAdmin, providerRewardsRecipient, defaultAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    uint256 internal _nextAttesterOffset;

    function _createMockKeys(uint256 count) internal pure returns (IStakingManager.KeyStore[] memory) {
        return _createMockKeysFrom(count, 0);
    }

    function _createMockKeysFrom(uint256 count, uint256 offset)
        internal
        pure
        returns (IStakingManager.KeyStore[] memory)
    {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            uint256 idx = offset + i;
            keys[i] = IStakingManager.KeyStore({
                attester: address(uint160(idx + 1)),
                publicKeyG1: G1Point({ x: idx, y: idx + 1 }),
                publicKeyG2: G2Point({ x0: idx, x1: idx + 1, y0: idx + 2, y1: idx + 3 }),
                proofOfPossession: G1Point({ x: idx + 10, y: idx + 11 })
            });
        }
        return keys;
    }

    function _addKeys(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeysFrom(count, _nextAttesterOffset);
        _nextAttesterOffset += count;
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsConfig() external view {
        assertEq(registry.stakingManager(), stakingManager);
        IStakingManager.ProviderConfig memory config = registry.getStakingProviderConfig();
        assertEq(config.admin, providerAdmin);
        assertEq(config.rewardsRecipient, providerRewardsRecipient);
    }

    function test_Initialize_GrantsRoles() external view {
        assertTrue(registry.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(registry.hasRole(STAKING_PROVIDER_ADMIN_ROLE, providerAdmin));
    }

    function test_Initialize_EmitsProviderSet() external {
        StakingProviderRegistry implementation = new StakingProviderRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        StakingProviderRegistry newRegistry = StakingProviderRegistry(address(proxy));

        vm.expectEmit(true, true, true, true, address(newRegistry));
        emit ProviderSet(providerAdmin, providerRewardsRecipient);

        newRegistry.initialize(stakingManager, providerAdmin, providerRewardsRecipient, defaultAdmin);
    }

    function test_RevertWhen_InitializeZeroAddress() external {
        StakingProviderRegistry implementation = new StakingProviderRegistry();

        // Zero stakingManager
        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingProviderRegistry newRegistry = StakingProviderRegistry(address(proxy));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStakingProviderRegistry.StakingProviderRegistry__ZeroAddress.selector, "stakingManager"
                )
            );
            newRegistry.initialize(address(0), providerAdmin, providerRewardsRecipient, defaultAdmin);
        }

        // Zero providerAdmin
        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingProviderRegistry newRegistry = StakingProviderRegistry(address(proxy));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStakingProviderRegistry.StakingProviderRegistry__ZeroAddress.selector, "providerAdmin"
                )
            );
            newRegistry.initialize(stakingManager, address(0), providerRewardsRecipient, defaultAdmin);
        }

        // Zero providerRewardsRecipient
        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingProviderRegistry newRegistry = StakingProviderRegistry(address(proxy));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStakingProviderRegistry.StakingProviderRegistry__ZeroAddress.selector, "providerRewardsRecipient"
                )
            );
            newRegistry.initialize(stakingManager, providerAdmin, address(0), defaultAdmin);
        }

        // Zero defaultAdmin
        {
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            StakingProviderRegistry newRegistry = StakingProviderRegistry(address(proxy));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStakingProviderRegistry.StakingProviderRegistry__ZeroAddress.selector, "defaultAdmin"
                )
            );
            newRegistry.initialize(stakingManager, providerAdmin, providerRewardsRecipient, address(0));
        }
    }

    function test_RevertWhen_InitializeCalledTwice() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(stakingManager, providerAdmin, providerRewardsRecipient, defaultAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                      ADD KEYS TO PROVIDER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddKeysToProvider_AddsKeys() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(3);

        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);

        assertEq(registry.getQueueLength(), 3);
    }

    function test_AddKeysToProvider_AddsMultipleBatches() external {
        _addKeys(2);
        assertEq(registry.getQueueLength(), 2);

        _addKeys(3);
        assertEq(registry.getQueueLength(), 5);
    }

    function test_AddKeysToProvider_EmitsEvent() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        address[] memory expectedAttesters = new address[](2);
        expectedAttesters[0] = keys[0].attester;
        expectedAttesters[1] = keys[1].attester;

        vm.expectEmit(true, true, true, true);
        emit KeysAddedToProvider(expectedAttesters);

        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);
    }

    function test_RevertWhen_AddKeysToProvider_Unauthorized() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, STAKING_PROVIDER_ADMIN_ROLE
            )
        );
        vm.prank(alice);
        registry.addKeysToProvider(keys);
    }

    function test_RevertWhen_AddKeysToProvider_EmptyArray() external {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](0);

        vm.expectRevert(IStakingProviderRegistry.StakingProviderRegistry__ZeroAmount.selector);
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);
    }

    function test_RevertWhen_AddKeysToProvider_DuplicateInSameBatch() external {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](2);
        keys[0] = IStakingManager.KeyStore({
            attester: address(uint160(999)),
            publicKeyG1: G1Point({ x: 0, y: 1 }),
            publicKeyG2: G2Point({ x0: 0, x1: 1, y0: 2, y1: 3 }),
            proofOfPossession: G1Point({ x: 10, y: 11 })
        });
        keys[1] = keys[0]; // duplicate

        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingProviderRegistry.StakingProviderRegistry__DuplicateAttester.selector, address(uint160(999))
            )
        );
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);
    }

    function test_RevertWhen_AddKeysToProvider_DuplicateAcrossBatches() external {
        _addKeys(3);

        // Try to add a key with the same attester address as the first batch
        IStakingManager.KeyStore[] memory keys = _createMockKeysFrom(1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingProviderRegistry.StakingProviderRegistry__DuplicateAttester.selector, keys[0].attester
            )
        );
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);
    }

    function test_AddKeysToProvider_AllowsReAddAfterDequeue() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeysFrom(1, 0);
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);

        // Dequeue via staking manager
        vm.prank(stakingManager);
        registry.getAttesterKeystore();

        // Same attester can be re-added after dequeue
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);
        assertEq(registry.getQueueLength(), 1);
    }

    function test_RevertWhen_AddKeysToProvider_DuplicateAgainstPartiallyConsumedQueue() external {
        // Add 3 keys (attesters at offsets 0, 1, 2)
        _addKeys(3);

        // Dequeue the first key (offset 0), leaving offsets 1 and 2 in queue
        vm.prank(stakingManager);
        registry.getAttesterKeystore();

        assertEq(registry.getQueueLength(), 2);

        // Try to add a key matching offset 1 (still in queue) — should revert
        IStakingManager.KeyStore[] memory duplicate = _createMockKeysFrom(1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingProviderRegistry.StakingProviderRegistry__DuplicateAttester.selector, duplicate[0].attester
            )
        );
        vm.prank(providerAdmin);
        registry.addKeysToProvider(duplicate);
    }

    function test_AddKeysToProvider_AllowsReAddAfterDrip() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeysFrom(1, 0);
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);

        // Drip the key
        vm.prank(providerAdmin);
        registry.dripQueue(1);

        // Same attester can be re-added after drip
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);
        assertEq(registry.getQueueLength(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                          DRIP QUEUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DripQueue_RemovesKeys() external {
        _addKeys(5);

        vm.prank(providerAdmin);
        registry.dripQueue(2);

        assertEq(registry.getQueueLength(), 3);
    }

    function test_DripQueue_DripsMoreThanAvailable() external {
        _addKeys(3);

        vm.prank(providerAdmin);
        registry.dripQueue(5);

        assertEq(registry.getQueueLength(), 0);
    }

    function test_DripQueue_EmitsEvents() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);

        vm.expectEmit(true, true, true, true);
        emit QueueDripped(keys[0].attester);

        vm.prank(providerAdmin);
        registry.dripQueue(1);
    }

    function test_RevertWhen_DripQueue_Empty() external {
        vm.expectRevert(IStakingProviderRegistry.StakingProviderRegistry__QueueEmpty.selector);
        vm.prank(providerAdmin);
        registry.dripQueue(1);
    }

    function test_RevertWhen_DripQueue_ZeroCount() external {
        _addKeys(3);

        vm.expectRevert(IStakingProviderRegistry.StakingProviderRegistry__ZeroAmount.selector);
        vm.prank(providerAdmin);
        registry.dripQueue(0);
    }

    function test_RevertWhen_DripQueue_Unauthorized() external {
        _addKeys(3);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, STAKING_PROVIDER_ADMIN_ROLE
            )
        );
        vm.prank(alice);
        registry.dripQueue(1);
    }

    /*//////////////////////////////////////////////////////////////
                   SET PROVIDER REWARDS RECIPIENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProviderRewardsRecipient() external {
        vm.expectEmit(true, true, true, true);
        emit ProviderSet(providerAdmin, alice);

        vm.prank(providerAdmin);
        registry.setProviderRewardsRecipient(alice);

        IStakingManager.ProviderConfig memory config = registry.getStakingProviderConfig();
        assertEq(config.rewardsRecipient, alice);
    }

    function test_RevertWhen_SetProviderRewardsRecipient_ZeroAddress() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingProviderRegistry.StakingProviderRegistry__ZeroAddress.selector, "rewardsRecipient"
            )
        );
        vm.prank(providerAdmin);
        registry.setProviderRewardsRecipient(address(0));
    }

    function test_RevertWhen_SetProviderRewardsRecipient_Unauthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, STAKING_PROVIDER_ADMIN_ROLE
            )
        );
        vm.prank(alice);
        registry.setProviderRewardsRecipient(bob);
    }

    /*//////////////////////////////////////////////////////////////
                      GET ATTESTER KEYSTORE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetAttesterKeystore_ReturnsAndRemovesKey() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(3);
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);

        vm.prank(stakingManager);
        IStakingManager.KeyStore memory keyStore = registry.getAttesterKeystore();

        assertEq(keyStore.attester, keys[0].attester);
        assertEq(registry.getQueueLength(), 2);
    }

    function test_GetAttesterKeystore_FIFOOrder() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(3);
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);

        vm.prank(stakingManager);
        IStakingManager.KeyStore memory first = registry.getAttesterKeystore();
        assertEq(first.attester, keys[0].attester);

        vm.prank(stakingManager);
        IStakingManager.KeyStore memory second = registry.getAttesterKeystore();
        assertEq(second.attester, keys[1].attester);

        vm.prank(stakingManager);
        IStakingManager.KeyStore memory third = registry.getAttesterKeystore();
        assertEq(third.attester, keys[2].attester);
    }

    function test_RevertWhen_GetAttesterKeystore_EmptyQueue() external {
        vm.expectRevert(IStakingProviderRegistry.StakingProviderRegistry__QueueEmpty.selector);
        vm.prank(stakingManager);
        registry.getAttesterKeystore();
    }

    function test_RevertWhen_GetAttesterKeystore_Unauthorized() external {
        _addKeys(3);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingProviderRegistry.StakingProviderRegistry__UnauthorizedStakingManager.selector, alice
            )
        );
        vm.prank(alice);
        registry.getAttesterKeystore();
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetQueueLength_InitiallyZero() external view {
        assertEq(registry.getQueueLength(), 0);
    }

    function test_GetStakingProviderConfig_InitiallySet() external view {
        IStakingManager.ProviderConfig memory config = registry.getStakingProviderConfig();
        assertEq(config.admin, providerAdmin);
        assertEq(config.rewardsRecipient, providerRewardsRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                          ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RoleGranting_AdditionalProviderAdmin() external {
        vm.prank(defaultAdmin);
        registry.grantRole(STAKING_PROVIDER_ADMIN_ROLE, alice);

        assertTrue(registry.hasRole(STAKING_PROVIDER_ADMIN_ROLE, alice));

        // Alice can now add keys
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(alice);
        registry.addKeysToProvider(keys);

        assertEq(registry.getQueueLength(), 1);
    }

    function test_RoleRevoking_RemovesAccess() external {
        vm.prank(defaultAdmin);
        registry.revokeRole(STAKING_PROVIDER_ADMIN_ROLE, providerAdmin);

        assertFalse(registry.hasRole(STAKING_PROVIDER_ADMIN_ROLE, providerAdmin));

        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, providerAdmin, STAKING_PROVIDER_ADMIN_ROLE
            )
        );
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_AddKeysAndDrip(uint8 addCount, uint8 dripCount) external {
        addCount = uint8(bound(addCount, 1, 50));
        dripCount = uint8(bound(dripCount, 1, addCount));

        _addKeys(addCount);
        assertEq(registry.getQueueLength(), addCount);

        vm.prank(providerAdmin);
        registry.dripQueue(dripCount);

        assertEq(registry.getQueueLength(), addCount - dripCount);
    }

    function testFuzz_MultipleAddAndDripCycles(uint8 cycleCount) external {
        cycleCount = uint8(bound(cycleCount, 1, 10));

        uint256 totalKeys;
        uint256 offset;
        for (uint256 i; i < cycleCount; ++i) {
            uint8 addCount = uint8(bound(uint256(keccak256(abi.encode(i, "add"))), 1, 10));
            uint8 dripCount = uint8(bound(uint256(keccak256(abi.encode(i, "drip"))), 0, addCount));

            IStakingManager.KeyStore[] memory keys = _createMockKeysFrom(addCount, offset);
            offset += addCount;
            vm.prank(providerAdmin);
            registry.addKeysToProvider(keys);
            totalKeys += addCount;

            if (dripCount > 0 && dripCount <= totalKeys) {
                vm.prank(providerAdmin);
                registry.dripQueue(dripCount);
                totalKeys -= dripCount;
            }
        }

        assertEq(registry.getQueueLength(), totalKeys);
    }
}
