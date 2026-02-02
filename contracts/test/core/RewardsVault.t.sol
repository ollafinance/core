// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { RewardsVault } from "src/core/RewardsVault.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";

contract RewardsVaultTest is Test {
    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardsRecorded(uint256 indexed delta);
    event RewardsWithdrawn(uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    MockAztec internal aztec;
    RewardsVault internal vault;

    address internal core;
    address internal defaultAdmin;
    address internal alice;

    function setUp() external {
        core = makeAddr("core");
        defaultAdmin = makeAddr("defaultAdmin");
        alice = makeAddr("alice");

        aztec = new MockAztec(address(this));
        vault = _deployRewardsVault(IERC20(address(aztec)), core, defaultAdmin);
    }

    function _deployRewardsVault(IERC20 rewardsToken_, address core_, address defaultAdmin_)
        internal
        returns (RewardsVault)
    {
        RewardsVault implementation = new RewardsVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        RewardsVault deployed = RewardsVault(address(proxy));
        deployed.initialize(rewardsToken_, core_, defaultAdmin_);
        return deployed;
    }

    function _deployUninitializedRewardsVault() internal returns (RewardsVault) {
        RewardsVault implementation = new RewardsVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        return RewardsVault(address(proxy));
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
        RewardsVault v = _deployUninitializedRewardsVault();

        vm.expectRevert(abi.encodeWithSelector(IRewardsVault.RewardsVault__ZeroAddress.selector, "rewardsToken"));
        v.initialize(IERC20(address(0)), core, defaultAdmin);
    }

    function test_RevertWhen_Initialize_CoreZeroAddress() external {
        RewardsVault v = _deployUninitializedRewardsVault();

        vm.expectRevert(abi.encodeWithSelector(IRewardsVault.RewardsVault__ZeroAddress.selector, "core"));
        v.initialize(IERC20(address(aztec)), address(0), defaultAdmin);
    }

    function test_RevertWhen_Initialize_DefaultAdminZeroAddress() external {
        RewardsVault v = _deployUninitializedRewardsVault();

        vm.expectRevert(abi.encodeWithSelector(IRewardsVault.RewardsVault__ZeroAddress.selector, "defaultAdmin"));
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
        vm.expectRevert(abi.encodeWithSelector(IRewardsVault.RewardsVault__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        vault.recordRewards();
    }

    function test_PostReceiveFundsHook_RecordsRewards_ReturnsDelta() external {
        uint256 amount = 10 ether;
        aztec.mint(address(vault), amount);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsRecorded(amount);

        vm.prank(core);
        uint256 balanceDelta = vault.recordRewards();

        assertEq(balanceDelta, amount);
        assertEq(vault.latestRecordedRewardsAmount(), amount);
        assertEq(vault.balance(), amount);
    }

    function test_PostReceiveFundsHook_RecordsDeltaWithDirectTransfers() external {
        uint256 first = 100 ether;
        aztec.mint(address(vault), first);
        vm.prank(core);
        vault.recordRewards();

        // Direct transfer (simulating permissionless harvest or direct send)
        uint256 directTransfer = 25 ether;
        aztec.mint(address(vault), directTransfer);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsRecorded(directTransfer);

        vm.prank(core);
        uint256 balanceDelta = vault.recordRewards();

        assertEq(balanceDelta, directTransfer);
        assertEq(vault.latestRecordedRewardsAmount(), first + directTransfer);
        assertEq(vault.balance(), first + directTransfer);
    }

    function test_RevertWhen_PostReceiveFundsHook_BalanceDecreasedSinceLastRecord() external {
        uint256 first = 100 ether;
        aztec.mint(address(vault), first);
        vm.prank(core);
        vault.recordRewards();

        vm.prank(address(vault));
        aztec.transfer(alice, 10 ether);

        vm.expectRevert(IRewardsVault.RewardsVault__BalanceMismatch.selector);
        vm.prank(core);
        vault.recordRewards();
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_WithdrawToCore_Unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(IRewardsVault.RewardsVault__UnauthorizedCore.selector, alice));
        vm.prank(alice);
        vault.withdrawToCore();
    }

    function test_RevertWhen_WithdrawToCore_ZeroBalance() external {
        vm.expectRevert(IRewardsVault.RewardsVault__ZeroAmount.selector);
        vm.prank(core);
        vault.withdrawToCore();
    }

    function test_RevertWhen_WithdrawToCore_BalanceMismatch_WhenNotRecorded() external {
        aztec.mint(address(vault), 1 ether);

        vm.expectRevert(IRewardsVault.RewardsVault__BalanceMismatch.selector);
        vm.prank(core);
        vault.withdrawToCore();
    }

    function test_WithdrawToCore_TransfersAndUpdatesAccounting() external {
        uint256 amount = 10 ether;
        aztec.mint(address(vault), amount);

        vm.prank(core);
        vault.recordRewards();

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
        vault.recordRewards();
        vm.prank(core);
        vault.withdrawToCore();

        uint256 second = 7 ether;
        aztec.mint(address(vault), second);
        vm.prank(core);
        vault.recordRewards();
        vm.prank(core);
        vault.withdrawToCore();

        assertEq(vault.latestRecordedRewardsAmount(), 0);
        assertEq(vault.balance(), 0);
    }
}
