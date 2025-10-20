// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import "../src/StakingStub.sol";
import "../src/testAZTEC.sol";

contract StakingStubTest is Test {
    StakingStub public stakingStub;
    testAZTEC public aztecToken;

    address public user = address(0x123);
    address public operator = address(0x456);

    function setUp() public {
        aztecToken = new testAZTEC();
        stakingStub = new StakingStub(address(aztecToken), address(this));

        // Mint tokens to user
        aztecToken.mint(user, 100 ether);
    }

    function testDeposit() public {
        vm.startPrank(user);

        // Approve staking stub to spend tokens
        aztecToken.approve(address(stakingStub), 32 ether);

        // Deposit
        stakingStub.deposit(user);

        // Check status and balance
        uint256 status = uint(stakingStub.status(user));
        uint256 balance = stakingStub.effectiveBalance(user);
        assertEq(status, 1); // VALIDATING
        assertEq(balance, 32 ether);

        vm.stopPrank();
    }

    function testWithdraw() public {
        vm.startPrank(user);

        // First deposit
        aztecToken.approve(address(stakingStub), 32 ether);
        stakingStub.deposit(user);

        // Initiate withdrawal
        stakingStub.initiateWithdraw(user, user);

        uint256 status2 = uint(stakingStub.status(user));
        assertEq(status2, 3); // EXITING

        // Warp time to after exit delay
        vm.warp(block.timestamp + 1 days + 1);

        // Finalise withdrawal
        uint256 balanceBefore = aztecToken.balanceOf(user);
        stakingStub.finaliseWithdraw(user);
        uint256 balanceAfter = aztecToken.balanceOf(user);

        assertEq(balanceAfter - balanceBefore, 32 ether);

        vm.stopPrank();
    }

    function testCannotDepositTwice() public {
        vm.startPrank(user);

        aztecToken.approve(address(stakingStub), 64 ether);

        stakingStub.deposit(user);

        vm.expectRevert("Already deposited");
        stakingStub.deposit(user);

        vm.stopPrank();
    }
}