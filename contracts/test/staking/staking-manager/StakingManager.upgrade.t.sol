// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { MockOllaCoreGovernance } from "test/mocks/MockOllaCoreGovernance.sol";

contract StakingManagerUpgradeMock is StakingManager {
    uint256 public v2Value;

    function setV2Value(uint256 value) external {
        v2Value = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract StakingManagerUpgradeTest is Test {
    event Upgraded(address indexed implementation);

    uint256 internal constant ACTIVATION_THRESHOLD = 100 ether;

    MockAztec internal aztec;
    MockAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    MockRewardsAccumulator internal rewardsAccumulator;

    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;

    address internal core;
    address internal providerAdmin;
    address internal defaultAdmin;
    MockOllaCoreGovernance internal mockCore;

    function setUp() external {
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        defaultAdmin = makeAddr("defaultAdmin");

        mockCore = new MockOllaCoreGovernance(defaultAdmin);
        core = address(mockCore);

        aztec = new MockAztec(address(this));
        rollup = new MockAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        rollupRegistry = new MockAztecRollupRegistry(address(rollup));
        rewardsAccumulator = new MockRewardsAccumulator(IERC20(address(aztec)), core);

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
            address(rewardsAccumulator),
            core,
            address(stakingProviderRegistry),
            defaultAdmin
        );
    }

    function _createMockKeys(uint256 count) internal pure returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = IStakingManager.KeyStore({
                // forge-lint: disable-next-line(unsafe-typecast)
                attester: address(uint160(i + 1)),
                publicKeyG1: G1Point({ x: i, y: i + 1 }),
                publicKeyG2: G2Point({ x0: i, x1: i + 1, y0: i + 2, y1: i + 3 }),
                proofOfPossession: G1Point({ x: i + 10, y: i + 11 })
            });
        }
        return keys;
    }

    function test_RevertWhen_UnauthorizedUpgrade() external {
        StakingManagerUpgradeMock newImplementation = new StakingManagerUpgradeMock();
        address attacker = makeAddr("attacker");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, stakingManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        stakingManager.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_DefaultAdminButNotGovernance_Upgrade() external {
        StakingManagerUpgradeMock newImplementation = new StakingManagerUpgradeMock();
        address otherAdmin = makeAddr("otherAdmin");

        // defaultAdmin is the sole governance address; grant DEFAULT_ADMIN_ROLE to a different account
        bytes32 defaultAdminRole = stakingManager.DEFAULT_ADMIN_ROLE();
        vm.prank(defaultAdmin);
        stakingManager.grantRole(defaultAdminRole, otherAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(StakingManager.StakingManager__UnauthorizedGovernance.selector, otherAdmin)
        );
        vm.prank(otherAdmin);
        stakingManager.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_UpgradeToZeroImplementation() external {
        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__ZeroAddress.selector, "newImplementation")
        );
        vm.prank(defaultAdmin);
        stakingManager.upgradeToAndCall(address(0), "");
    }

    function test_RevertWhen_UpgradeCalledOnImplementationDirectly() external {
        StakingManagerUpgradeMock newImplementation = new StakingManagerUpgradeMock();
        StakingManager implementation = new StakingManager();

        vm.expectRevert();
        vm.prank(defaultAdmin);
        implementation.upgradeToAndCall(address(newImplementation), "");
    }

    function test_GovernanceCanUpgrade_PreservesState() external {
        address rewardsRecipient = makeAddr("rewardsRecipient");

        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        vm.prank(providerAdmin);
        stakingProviderRegistry.setProviderRewardsRecipient(rewardsRecipient);

        uint256 queueLengthBefore = stakingProviderRegistry.getQueueLength();
        uint256 activatedBefore = stakingManager.getActivatedAttesterCount();
        uint256 pendingBefore = stakingManager.getPendingUnstakeCount();
        IStakingManager.ProviderConfig memory providerBefore = stakingManager.getProviderConfig();
        address assetBefore = address(stakingManager.stakingAsset());
        address rollupRegistryBefore = address(stakingManager.rollupRegistry());
        address rewardsAccumulatorBefore = address(stakingManager.rewardsAccumulator());
        address coreBefore = stakingManager.core();
        address ownerBefore = mockCore.owner();

        StakingManagerUpgradeMock newImplementation = new StakingManagerUpgradeMock();

        vm.expectEmit(true, true, false, true, address(stakingManager));
        emit Upgraded(address(newImplementation));

        vm.prank(defaultAdmin);
        stakingManager.upgradeToAndCall(address(newImplementation), "");

        StakingManagerUpgradeMock v2 = StakingManagerUpgradeMock(address(stakingManager));
        assertEq(v2.version(), 2, "upgrade applied");
        assertEq(stakingProviderRegistry.getQueueLength(), queueLengthBefore, "queue length preserved");
        assertEq(v2.getActivatedAttesterCount(), activatedBefore, "activated preserved");
        assertEq(v2.getPendingUnstakeCount(), pendingBefore, "pending preserved");
        IStakingManager.ProviderConfig memory providerAfter = v2.getProviderConfig();
        assertEq(providerAfter.rewardsRecipient, providerBefore.rewardsRecipient, "rewards recipient preserved");
        assertEq(address(v2.stakingAsset()), assetBefore, "asset preserved");
        assertEq(address(v2.rollupRegistry()), rollupRegistryBefore, "rollup registry preserved");
        assertEq(address(v2.rewardsAccumulator()), rewardsAccumulatorBefore, "rewards vault preserved");
        assertEq(v2.core(), coreBefore, "core preserved");
        assertEq(mockCore.owner(), ownerBefore, "owner preserved");

        v2.setV2Value(123);
        assertEq(v2.v2Value(), 123, "v2 storage works");
    }
}
