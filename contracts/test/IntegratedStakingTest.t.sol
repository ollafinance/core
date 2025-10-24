// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Aztlan Labs

pragma solidity ^0.8.19;

import {Test, console} from "@forge-std/Test.sol";
import {MinimalVault} from "../src/MinimalVault.sol";
import {StakingStub} from "../src/StakingStub.sol";
import {testAZTEC} from "../src/testAZTEC.sol";

contract IntegratedStakingTest is Test {
    MinimalVault public vault;
    StakingStub public stakingStub;
    testAZTEC public aztecToken;

    address public user = address(0x1);
    address public operator = address(0x2);
    address public guardian = address(0x3);

    uint256 public constant INITIAL_MINT = 1000 ether;
    uint256 public constant DEPOSIT_AMOUNT = 32 ether; // Staking requirement

    function setUp() public {
        // Deploy contracts
        aztecToken = new testAZTEC();
        stakingStub = new StakingStub(address(aztecToken), operator);
        vault = new MinimalVault(address(aztecToken), operator, guardian);

        // Mint tokens to user
        aztecToken.mint(user, INITIAL_MINT);

        // Approve vault to spend user's tokens
        vm.prank(user);
        aztecToken.approve(address(vault), INITIAL_MINT);

        // Operator approves staking stub to spend their tokens
        vm.prank(operator);
        aztecToken.approve(address(stakingStub), INITIAL_MINT);
    }

    function test_UserDepositAndOperatorStaking() public {
        // Step 1: User deposits to vault
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        // Verify vault state
        assertEq(vault.userShares(user), DEPOSIT_AMOUNT);
        assertEq(vault.totalShares(), DEPOSIT_AMOUNT);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);

        // Verify tokens transferred to operator
        assertEq(aztecToken.balanceOf(user), INITIAL_MINT - DEPOSIT_AMOUNT);
        assertEq(aztecToken.balanceOf(address(vault)), 0);
        assertEq(aztecToken.balanceOf(operator), DEPOSIT_AMOUNT);

        // Step 2: Operator stakes the tokens
        vm.prank(operator);
        stakingStub.deposit(operator);

        // Verify staking state
        uint256 status = uint256(stakingStub.status(operator));
        uint256 balance = stakingStub.effectiveBalance(operator);
        assertEq(status, 1); // VALIDATING
        assertEq(balance, DEPOSIT_AMOUNT);

        // Verify operator's token balance (transferred to staking contract)
        assertEq(aztecToken.balanceOf(operator), 0);
        assertEq(aztecToken.balanceOf(address(stakingStub)), DEPOSIT_AMOUNT);
    }

    function test_StakingRewardsFlow() public {
        // User deposits and operator stakes
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        vm.prank(operator);
        stakingStub.deposit(operator);

        // Simulate staking rewards (mint additional tokens to operator)
        uint256 rewardAmount = 1 ether;
        aztecToken.mint(operator, rewardAmount);

        // Operator approves vault to spend rewards
        vm.prank(operator);
        aztecToken.approve(address(vault), rewardAmount);

        // Operator processes rewards back to vault
        vm.prank(operator);
        vault.processRewards(rewardAmount);

        // Verify rewards increase vault assets
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT + rewardAmount);
        assertEq(vault.accumulatedRewards(), rewardAmount);

        // User's share value has increased proportionally
        uint256 userAssets = vault.calculateAssets(vault.userShares(user));
        assertEq(userAssets, DEPOSIT_AMOUNT + rewardAmount); // Full rewards accrue to single user
    }

    function test_OperatorWithdrawal() public {
        // Deposit and stake
        vm.prank(user);
        vault.deposit(DEPOSIT_AMOUNT);

        vm.prank(operator);
        stakingStub.deposit(operator);

        // Operator initiates withdrawal from staking
        vm.prank(operator);
        stakingStub.initiateWithdraw(operator, operator);

        // Verify exiting status
        uint256 exitStatus = uint256(stakingStub.status(operator));
        assertEq(exitStatus, 3); // EXITING

        // Warp time past exit delay
        vm.warp(block.timestamp + stakingStub.exitDelay() + 1);

        // Finalize withdrawal
        uint256 operatorBalanceBefore = aztecToken.balanceOf(operator);
        vm.prank(operator);
        stakingStub.finaliseWithdraw(operator);
        uint256 operatorBalanceAfter = aztecToken.balanceOf(operator);

        // Operator gets tokens back
        assertEq(operatorBalanceAfter - operatorBalanceBefore, DEPOSIT_AMOUNT);

        // Status reset
        uint256 finalStatus = uint256(stakingStub.status(operator));
        uint256 finalBalance = stakingStub.effectiveBalance(operator);
        assertEq(finalStatus, 0); // NONE
        assertEq(finalBalance, 0);
    }
}
