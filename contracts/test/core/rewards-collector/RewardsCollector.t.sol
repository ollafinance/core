// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { RewardsCollector } from "src/core/RewardsCollector.sol";
import { IRewardsCollector } from "src/core/interfaces/IRewardsCollector.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";

contract RewardsCollectorTest is Test {
    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardsRecorded(uint256 indexed delta);
    event RewardsWithdrawn(uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    MockAztec internal aztec;
    RewardsCollector internal vault;

    address internal core;
    address internal defaultAdmin;
    address internal alice;

    function setUp() external {
        core = makeAddr("core");
        defaultAdmin = makeAddr("defaultAdmin");
        alice = makeAddr("alice");

        aztec = new MockAztec(address(this));
        vault = _deployRewardsCollector(IERC20(address(aztec)), core, defaultAdmin);
    }

    function _deployRewardsCollector(IERC20 rewardsToken_, address core_, address defaultAdmin_)
        internal
        returns (RewardsCollector)
    {
        RewardsCollector implementation = new RewardsCollector();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        RewardsCollector deployed = RewardsCollector(address(proxy));
        deployed.initialize(rewardsToken_, core_, defaultAdmin_);
        return deployed;
    }

    function _deployUninitializedRewardsCollector() internal returns (RewardsCollector) {
        RewardsCollector implementation = new RewardsCollector();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        return RewardsCollector(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsConfigAndRoles() external view {
        assertEq(address(vault.rewardsToken()), address(aztec));
        assertEq(vault.core(), core);

        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), defaultAdmin));
    }

    function test_RevertWhen_Initialize_RewardsTokenZeroAddress() external {
        RewardsCollector v = _deployUninitializedRewardsCollector();

        vm.expectRevert(
            abi.encodeWithSelector(IRewardsCollector.RewardsCollector__ZeroAddress.selector, "rewardsToken")
        );
        v.initialize(IERC20(address(0)), core, defaultAdmin);
    }

    function test_RevertWhen_Initialize_CoreZeroAddress() external {
        RewardsCollector v = _deployUninitializedRewardsCollector();

        vm.expectRevert(abi.encodeWithSelector(IRewardsCollector.RewardsCollector__ZeroAddress.selector, "core"));
        v.initialize(IERC20(address(aztec)), address(0), defaultAdmin);
    }

    function test_RevertWhen_Initialize_DefaultAdminZeroAddress() external {
        RewardsCollector v = _deployUninitializedRewardsCollector();

        vm.expectRevert(
            abi.encodeWithSelector(IRewardsCollector.RewardsCollector__ZeroAddress.selector, "defaultAdmin")
        );
        v.initialize(IERC20(address(aztec)), core, address(0));
    }

    function test_RevertWhen_Reinitialize() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(IERC20(address(aztec)), core, defaultAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                        POST-RECEIVE HOOK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_PostReceiveFundsHook_Unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(IRewardsCollector.RewardsCollector__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        vault.recordBalance();
    }

    function test_PostReceiveFundsHook_RecordsRewards_ReturnsDelta() external {
        uint256 amount = 10 ether;
        aztec.mint(address(vault), amount);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsRecorded(amount);

        vm.prank(core);
        uint256 balanceDelta = vault.recordBalance();

        assertEq(balanceDelta, amount);
        assertEq(vault.latestRecordedRewardsAmount(), amount);
        assertEq(vault.balance(), amount);
    }

    function test_PostReceiveFundsHook_RecordsDeltaWithDirectTransfers() external {
        uint256 first = 100 ether;
        aztec.mint(address(vault), first);
        vm.prank(core);
        vault.recordBalance();

        // Direct transfer (simulating permissionless harvest or direct send)
        uint256 directTransfer = 25 ether;
        aztec.mint(address(vault), directTransfer);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsRecorded(directTransfer);

        vm.prank(core);
        uint256 balanceDelta = vault.recordBalance();

        assertEq(balanceDelta, directTransfer);
        assertEq(vault.latestRecordedRewardsAmount(), first + directTransfer);
        assertEq(vault.balance(), first + directTransfer);
    }

    function test_RevertWhen_PostReceiveFundsHook_BalanceDecreasedSinceLastRecord() external {
        uint256 first = 100 ether;
        aztec.mint(address(vault), first);
        vm.prank(core);
        vault.recordBalance();

        vm.prank(address(vault));
        aztec.transfer(alice, 10 ether);

        vm.expectRevert(IRewardsCollector.RewardsCollector__BalanceMismatch.selector);
        vm.prank(core);
        vault.recordBalance();
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_WithdrawToCore_Unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(IRewardsCollector.RewardsCollector__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        vault.withdrawToCore();
    }

    function test_RevertWhen_WithdrawToCore_ZeroBalance() external {
        vm.expectRevert(IRewardsCollector.RewardsCollector__ZeroAmount.selector);
        vm.prank(core);
        vault.withdrawToCore();
    }

    function test_RevertWhen_WithdrawToCore_BalanceMismatch_WhenNotRecorded() external {
        aztec.mint(address(vault), 1 ether);

        vm.expectRevert(IRewardsCollector.RewardsCollector__BalanceMismatch.selector);
        vm.prank(core);
        vault.withdrawToCore();
    }

    function test_WithdrawToCore_TransfersAndUpdatesAccounting() external {
        uint256 amount = 10 ether;
        aztec.mint(address(vault), amount);

        vm.prank(core);
        vault.recordBalance();

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsWithdrawn(amount);

        vm.prank(core);
        vault.withdrawToCore();

        assertEq(aztec.balanceOf(core) - coreBalanceBefore, amount);
        assertEq(vault.latestRecordedRewardsAmount(), 0);
        assertEq(vault.balance(), 0);
    }

    function test_WithdrawToCore_AccumulatesOverMultipleHarvests() external {
        uint256 first = 10 ether;
        aztec.mint(address(vault), first);
        vm.prank(core);
        vault.recordBalance();
        vm.prank(core);
        vault.withdrawToCore();

        uint256 second = 7 ether;
        aztec.mint(address(vault), second);
        vm.prank(core);
        vault.recordBalance();
        vm.prank(core);
        vault.withdrawToCore();

        assertEq(vault.latestRecordedRewardsAmount(), 0);
        assertEq(vault.balance(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    MID-CALL REWARD ARRIVAL TESTS (C9)
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawToCore_RevertsIfRewardArrivesAfterRecord() external {
        uint256 initialAmount = 10 ether;
        aztec.mint(address(vault), initialAmount);

        vm.prank(core);
        vault.recordBalance();

        uint256 extraAmount = 5 ether;
        aztec.mint(address(vault), extraAmount);

        vm.expectRevert(IRewardsCollector.RewardsCollector__BalanceMismatch.selector);
        vm.prank(core);
        vault.withdrawToCore();
    }

    function test_WithdrawToCore_SucceedsAfterReRecord() external {
        uint256 initialAmount = 10 ether;
        aztec.mint(address(vault), initialAmount);

        vm.prank(core);
        vault.recordBalance();

        uint256 extraAmount = 5 ether;
        aztec.mint(address(vault), extraAmount);

        vm.prank(core);
        vault.recordBalance();

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.prank(core);
        vault.withdrawToCore();

        assertEq(aztec.balanceOf(core) - coreBalanceBefore, initialAmount + extraAmount);
        assertEq(vault.latestRecordedRewardsAmount(), 0);
        assertEq(vault.balance(), 0);
    }
}
