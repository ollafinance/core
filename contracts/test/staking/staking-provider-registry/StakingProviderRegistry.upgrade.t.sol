// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockOllaCoreGovernance } from "test/mocks/MockOllaCoreGovernance.sol";

contract StakingProviderRegistryUpgradeMock is StakingProviderRegistry {
    uint256 public v2Value;

    function setV2Value(uint256 value) external {
        v2Value = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract StakingProviderRegistryUpgradeTest is Test {
    event Upgraded(address indexed implementation);

    bytes32 internal constant STAKING_PROVIDER_ADMIN_ROLE = keccak256("STAKING_PROVIDER_ADMIN_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    StakingProviderRegistry internal registry;
    MockStakingManager internal mockStakingManager;
    MockOllaCoreGovernance internal mockCore;

    address internal stakingManager;
    address internal providerAdmin;
    address internal providerRewardsRecipient;
    address internal defaultAdmin;
    address internal attacker;

    function setUp() external {
        stakingManager = makeAddr("stakingManager");
        providerAdmin = makeAddr("providerAdmin");
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        defaultAdmin = makeAddr("defaultAdmin");
        attacker = makeAddr("attacker");

        mockCore = new MockOllaCoreGovernance(defaultAdmin);
        mockStakingManager = new MockStakingManager();
        mockStakingManager.initialize(
            IERC20(address(0)), address(0), address(0), address(mockCore), address(0), address(0)
        );
        stakingManager = address(mockStakingManager);

        StakingProviderRegistry implementation = new StakingProviderRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        registry = StakingProviderRegistry(address(proxy));

        registry.initialize(stakingManager, providerAdmin, providerRewardsRecipient, defaultAdmin);
    }

    uint256 internal _nextAttesterOffset;

    function _createMockKeys(uint256 count) internal returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            uint256 idx = _nextAttesterOffset + i;
            keys[i] = IStakingManager.KeyStore({
                attester: address(uint160(idx + 1)),
                publicKeyG1: G1Point({ x: idx, y: idx + 1 }),
                publicKeyG2: G2Point({ x0: idx, x1: idx + 1, y0: idx + 2, y1: idx + 3 }),
                proofOfPossession: G1Point({ x: idx + 10, y: idx + 11 })
            });
        }
        _nextAttesterOffset += count;
        return keys;
    }

    function _addKeys(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        vm.prank(providerAdmin);
        registry.addKeysToProvider(keys);
    }

    function test_RevertWhen_UnauthorizedUpgrade() external {
        StakingProviderRegistryUpgradeMock newImplementation = new StakingProviderRegistryUpgradeMock();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(attacker);
        registry.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_DefaultAdminButNotGovernance_Upgrade() external {
        StakingProviderRegistryUpgradeMock newImplementation = new StakingProviderRegistryUpgradeMock();
        address otherAdmin = makeAddr("otherAdmin");

        // defaultAdmin is the sole governance address; grant DEFAULT_ADMIN_ROLE to a different account
        vm.prank(defaultAdmin);
        registry.grantRole(DEFAULT_ADMIN_ROLE, otherAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingProviderRegistry.StakingProviderRegistry__UnauthorizedGovernance.selector, otherAdmin
            )
        );
        vm.prank(otherAdmin);
        registry.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_UpgradeToZeroImplementation() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingProviderRegistry.StakingProviderRegistry__ZeroAddress.selector, "newImplementation"
            )
        );
        vm.prank(defaultAdmin);
        registry.upgradeToAndCall(address(0), "");
    }

    function test_RevertWhen_UpgradeCalledOnImplementationDirectly() external {
        StakingProviderRegistryUpgradeMock newImplementation = new StakingProviderRegistryUpgradeMock();
        StakingProviderRegistry implementation = new StakingProviderRegistry();

        vm.expectRevert();
        vm.prank(defaultAdmin);
        implementation.upgradeToAndCall(address(newImplementation), "");
    }

    function test_GovernanceCanUpgrade_PreservesState() external {
        // Set up some initial state
        _addKeys(5);

        vm.prank(providerAdmin);
        registry.dripQueue(2);

        address newRewardsRecipient = makeAddr("newRewardsRecipient");
        vm.prank(providerAdmin);
        registry.setProviderRewardsRecipient(newRewardsRecipient);

        // Record state before upgrade
        uint256 queueLengthBefore = registry.getQueueLength();
        IStakingManager.ProviderConfig memory providerBefore = registry.getStakingProviderConfig();
        address stakingManagerBefore = registry.stakingManager();
        address ownerBefore = mockCore.owner();

        // Perform upgrade
        StakingProviderRegistryUpgradeMock newImplementation = new StakingProviderRegistryUpgradeMock();

        vm.expectEmit(true, true, false, true, address(registry));
        emit Upgraded(address(newImplementation));

        vm.prank(defaultAdmin);
        registry.upgradeToAndCall(address(newImplementation), "");

        // Verify state preserved
        StakingProviderRegistryUpgradeMock v2 = StakingProviderRegistryUpgradeMock(address(registry));
        assertEq(v2.version(), 2, "upgrade applied");
        assertEq(v2.getQueueLength(), queueLengthBefore, "queue length preserved");
        assertEq(v2.stakingManager(), stakingManagerBefore, "staking manager preserved");
        assertEq(mockCore.owner(), ownerBefore, "owner preserved");

        IStakingManager.ProviderConfig memory providerAfter = v2.getStakingProviderConfig();
        assertEq(providerAfter.rewardsRecipient, providerBefore.rewardsRecipient, "rewards recipient preserved");

        // Verify roles preserved
        assertTrue(v2.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin), "default admin role preserved");
        assertTrue(v2.hasRole(STAKING_PROVIDER_ADMIN_ROLE, providerAdmin), "provider admin role preserved");

        // Verify new functionality works
        v2.setV2Value(456);
        assertEq(v2.v2Value(), 456, "v2 storage works");
    }

    function test_GovernanceCanUpgrade_AfterCoreOwnerDrift() external {
        StakingProviderRegistryUpgradeMock newImplementation = new StakingProviderRegistryUpgradeMock();

        mockCore.setOwner(makeAddr("newCoreOwner"));

        vm.prank(defaultAdmin);
        registry.upgradeToAndCall(address(newImplementation), "");

        assertEq(
            StakingProviderRegistryUpgradeMock(address(registry)).version(), 2, "upgrade should ignore core owner drift"
        );
    }

    function test_Upgrade_PreservesStakingManagerAccess() external {
        _addKeys(3);

        // Record initial queue length
        uint256 queueLengthBefore = registry.getQueueLength();

        // Upgrade
        StakingProviderRegistryUpgradeMock newImplementation = new StakingProviderRegistryUpgradeMock();
        vm.prank(defaultAdmin);
        registry.upgradeToAndCall(address(newImplementation), "");

        StakingProviderRegistryUpgradeMock v2 = StakingProviderRegistryUpgradeMock(address(registry));

        // Verify staking manager can still dequeue
        vm.prank(stakingManager);
        IStakingManager.KeyStore memory keyStore = v2.getAttesterKeystore();
        assertEq(keyStore.attester, address(1), "first key returned");
        assertEq(v2.getQueueLength(), queueLengthBefore - 1, "queue length decremented");
    }

    function test_Upgrade_PreservesProviderAdminAccess() external {
        _addKeys(3);

        // Upgrade
        StakingProviderRegistryUpgradeMock newImplementation = new StakingProviderRegistryUpgradeMock();
        vm.prank(defaultAdmin);
        registry.upgradeToAndCall(address(newImplementation), "");

        StakingProviderRegistryUpgradeMock v2 = StakingProviderRegistryUpgradeMock(address(registry));

        // Verify provider admin can still add keys after upgrade
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        v2.addKeysToProvider(keys);

        assertEq(v2.getQueueLength(), 5, "new keys added after upgrade"); // 3 + 2
    }
}
