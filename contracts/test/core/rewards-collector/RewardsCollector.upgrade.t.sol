// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { RewardsCollector } from "src/core/RewardsCollector.sol";
import { IRewardsCollector } from "src/core/interfaces/IRewardsCollector.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockOllaCoreGovernance } from "test/mocks/MockOllaCoreGovernance.sol";

contract RewardsCollectorUpgradeMock is RewardsCollector {
    uint256 public v2Value;

    function setV2Value(uint256 value) external {
        v2Value = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract RewardsCollectorUpgradeTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Upgraded(address indexed implementation);

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal aztec;
    RewardsCollector internal vault;

    address internal core;
    address internal defaultAdmin;
    MockOllaCoreGovernance internal mockCore;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        defaultAdmin = makeAddr("defaultAdmin");

        mockCore = new MockOllaCoreGovernance(defaultAdmin);
        core = address(mockCore);

        aztec = new MockAztec(address(this));

        RewardsCollector implementation = new RewardsCollector();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = RewardsCollector(address(proxy));
        vault.initialize(IERC20(address(aztec)), core, defaultAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UnauthorizedUpgrade() external {
        RewardsCollectorUpgradeMock newImplementation = new RewardsCollectorUpgradeMock();
        address attacker = makeAddr("attacker");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_DefaultAdminButNotGovernance_Upgrade() external {
        RewardsCollectorUpgradeMock newImplementation = new RewardsCollectorUpgradeMock();
        address otherAdmin = makeAddr("otherAdmin");

        bytes32 defaultAdminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(defaultAdmin);
        vault.grantRole(defaultAdminRole, otherAdmin);

        vm.expectRevert(abi.encodeWithSelector(RewardsCollector.RewardsCollector__UnauthorizedGovernance.selector, otherAdmin));
        vm.prank(otherAdmin);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_UpgradeToZeroImplementation() external {
        vm.expectRevert(abi.encodeWithSelector(IRewardsCollector.RewardsCollector__ZeroAddress.selector, "newImplementation"));
        vm.prank(defaultAdmin);
        vault.upgradeToAndCall(address(0), "");
    }

    function test_RevertWhen_UpgradeCalledOnImplementationDirectly() external {
        RewardsCollectorUpgradeMock newImplementation = new RewardsCollectorUpgradeMock();
        RewardsCollector implementation = new RewardsCollector();

        vm.expectRevert();
        vm.prank(defaultAdmin);
        implementation.upgradeToAndCall(address(newImplementation), "");
    }

    function test_Upgrade_PreservesStateAndEmitsEvent() external {
        uint256 rewardAmount = 10 ether;
        aztec.mint(address(vault), rewardAmount);
        vm.prank(core);
        vault.recordBalance();

        address coreBefore = vault.core();
        address rewardsTokenBefore = address(vault.rewardsToken());
        uint256 latestRecordedBefore = vault.latestRecordedRewardsAmount();

        RewardsCollectorUpgradeMock newImplementation = new RewardsCollectorUpgradeMock();

        vm.expectEmit(true, true, false, true, address(vault));
        emit Upgraded(address(newImplementation));

        vm.prank(defaultAdmin);
        vault.upgradeToAndCall(address(newImplementation), "");

        RewardsCollectorUpgradeMock v2 = RewardsCollectorUpgradeMock(address(vault));
        assertEq(v2.version(), 2, "upgrade applied");
        assertEq(v2.core(), coreBefore, "core preserved");
        assertEq(address(v2.rewardsToken()), rewardsTokenBefore, "rewards token preserved");
        assertEq(v2.latestRecordedRewardsAmount(), latestRecordedBefore, "latest recorded preserved");

        v2.setV2Value(123);
        assertEq(v2.v2Value(), 123, "v2 storage works");
    }
}
