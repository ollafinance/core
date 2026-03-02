// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { MockOllaCoreGovernance } from "test/mocks/MockOllaCoreGovernance.sol";

interface IUpgradeTo {
    function upgradeTo(address newImplementation) external;
}

contract WithdrawalQueueUpgradeMock is WithdrawalQueue {
    uint256 public v2Value;

    function setV2Value(uint256 value) external {
        v2Value = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract WithdrawalQueueUpgradeTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Upgraded(address indexed implementation);

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    WithdrawalQueue internal queue;
    address internal vault;
    address internal admin;
    MockOllaCoreGovernance internal mockVault;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        admin = makeAddr("admin");

        mockVault = new MockOllaCoreGovernance(admin);
        vault = address(mockVault);

        WithdrawalQueue implementation = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        queue = WithdrawalQueue(address(proxy));
        queue.initialize(vault, admin, 50_000);
    }

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UnauthorizedUpgrade() external {
        WithdrawalQueueUpgradeMock newImplementation = new WithdrawalQueueUpgradeMock();
        address attacker = makeAddr("attacker");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, queue.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        queue.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_DefaultAdminButNotGovernance_Upgrade() external {
        WithdrawalQueueUpgradeMock newImplementation = new WithdrawalQueueUpgradeMock();
        address otherAdmin = makeAddr("otherAdmin");

        bytes32 defaultAdminRole = queue.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        queue.grantRole(defaultAdminRole, otherAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawalQueue.WithdrawalQueue__UnauthorizedGovernance.selector, otherAdmin)
        );
        vm.prank(otherAdmin);
        queue.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_UpgradeToZeroImplementation() external {
        vm.prank(admin);
        vm.expectRevert();
        IUpgradeTo(address(queue)).upgradeTo(address(0));
    }

    function test_RevertWhen_UpgradeToAndCallZeroImplementation() external {
        vm.expectRevert(
            abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__ZeroAddress.selector, "newImplementation")
        );
        vm.prank(admin);
        queue.upgradeToAndCall(address(0), "");
    }

    function test_RevertWhen_UpgradeCalledOnImplementationDirectly() external {
        WithdrawalQueueUpgradeMock newImplementation = new WithdrawalQueueUpgradeMock();
        WithdrawalQueue implementation = new WithdrawalQueue();

        vm.expectRevert();
        vm.prank(admin);
        implementation.upgradeToAndCall(address(newImplementation), "");
    }

    function test_Upgrade_PreservesStateAndEmitsEvent() external {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 aliceAssets = 100;
        uint256 bobAssets = 250;

        uint256 aliceId = _request(alice, 10, aliceAssets, 1e18);
        uint256 bobId = _request(bob, 20, bobAssets, 1.1e18);

        vm.prank(vault);
        queue.finalizeWithdrawals(aliceAssets);

        address vaultBefore = queue.vault();
        uint256 nextRequestIdBefore = queue.nextRequestId();
        uint256 nextPendingIdBefore = queue.nextPendingId();
        uint256 totalPendingAssetsBefore = queue.totalPendingAssets();
        IWithdrawalQueue.WithdrawalRequest memory aliceRequestBefore = queue.getRequest(aliceId);
        IWithdrawalQueue.WithdrawalRequest memory bobRequestBefore = queue.getRequest(bobId);

        WithdrawalQueueUpgradeMock newImplementation = new WithdrawalQueueUpgradeMock();

        vm.expectEmit(true, true, false, true, address(queue));
        emit Upgraded(address(newImplementation));

        vm.prank(admin);
        queue.upgradeToAndCall(address(newImplementation), "");

        WithdrawalQueueUpgradeMock v2 = WithdrawalQueueUpgradeMock(address(queue));
        assertEq(v2.version(), 2, "upgrade applied");
        assertEq(v2.vault(), vaultBefore, "vault preserved");
        assertEq(v2.nextRequestId(), nextRequestIdBefore, "next request id preserved");
        assertEq(v2.nextPendingId(), nextPendingIdBefore, "next pending id preserved");
        assertEq(v2.totalPendingAssets(), totalPendingAssetsBefore, "total pending assets preserved");

        IWithdrawalQueue.WithdrawalRequest memory aliceRequestAfter = v2.getRequest(aliceId);
        IWithdrawalQueue.WithdrawalRequest memory bobRequestAfter = v2.getRequest(bobId);

        assertEq(aliceRequestAfter.recipient, aliceRequestBefore.recipient, "alice recipient preserved");
        assertEq(aliceRequestAfter.finalized, aliceRequestBefore.finalized, "alice finalized preserved");
        assertEq(aliceRequestAfter.claimed, aliceRequestBefore.claimed, "alice claimed preserved");
        assertEq(aliceRequestAfter.shares, aliceRequestBefore.shares, "alice shares preserved");
        assertEq(aliceRequestAfter.assetsExpected, aliceRequestBefore.assetsExpected, "alice assets preserved");
        assertEq(aliceRequestAfter.rate, aliceRequestBefore.rate, "alice rate preserved");

        assertEq(bobRequestAfter.recipient, bobRequestBefore.recipient, "bob recipient preserved");
        assertEq(bobRequestAfter.finalized, bobRequestBefore.finalized, "bob finalized preserved");
        assertEq(bobRequestAfter.claimed, bobRequestBefore.claimed, "bob claimed preserved");
        assertEq(bobRequestAfter.shares, bobRequestBefore.shares, "bob shares preserved");
        assertEq(bobRequestAfter.assetsExpected, bobRequestBefore.assetsExpected, "bob assets preserved");
        assertEq(bobRequestAfter.rate, bobRequestBefore.rate, "bob rate preserved");

        v2.setV2Value(123);
        assertEq(v2.v2Value(), 123, "v2 storage works");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _request(address user, uint256 shares, uint256 assetsExpected, uint256 rate)
        internal
        returns (uint256 requestId)
    {
        vm.prank(vault);
        requestId = queue.requestWithdrawal(user, shares, assetsExpected, rate);
        return requestId;
    }
}
