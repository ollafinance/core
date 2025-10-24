// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Aztlan Labs

pragma solidity ^0.8.19;

import {Test, console} from "@forge-std/Test.sol";
import {MinimalVault} from "../src/MinimalVault.sol";
import {GuardianPause} from "../src/GuardianPause.sol";
import {testAZTEC} from "../src/testAZTEC.sol";

contract MinimalVaultTest is Test {
    MinimalVault public vault;
    GuardianPause public guardianPause;
    testAZTEC public aztecToken;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public operator = address(0x3);
    address public guardian = address(0x4);

    uint256 public constant INITIAL_MINT = 1000 ether;

    function setUp() public {
        // Deploy contracts
        aztecToken = new testAZTEC();
        guardianPause = new GuardianPause(guardian);
        vault = new MinimalVault(address(aztecToken), operator, guardian);

        // Mint tokens to users and operator
        aztecToken.mint(user1, INITIAL_MINT);
        aztecToken.mint(user2, INITIAL_MINT);
        aztecToken.mint(operator, INITIAL_MINT);

        // Approve vault to spend tokens
        vm.prank(user1);
        aztecToken.approve(address(vault), INITIAL_MINT);
        vm.prank(user2);
        aztecToken.approve(address(vault), INITIAL_MINT);
        vm.prank(operator);
        aztecToken.approve(address(vault), INITIAL_MINT);
    }

    function test_Deployment() public {
        assertEq(address(vault.aztecToken()), address(aztecToken));
        assertEq(vault.internalOperator(), operator);
        assertEq(vault.guardian(), guardian);
        assertEq(vault.paused(), false);
    }

    function test_Deposit() public {
        uint256 depositAmount = 100 ether;

        vm.prank(user1);
        vault.deposit(depositAmount);

        // Check user shares
        assertEq(vault.userShares(user1), depositAmount);
        assertEq(vault.totalShares(), depositAmount);
        assertEq(vault.totalAssets(), depositAmount);

        // Check token transfer
        assertEq(aztecToken.balanceOf(user1), INITIAL_MINT - depositAmount);
        assertEq(aztecToken.balanceOf(address(vault)), 0); // Tokens transferred to operator
        assertEq(aztecToken.balanceOf(operator), INITIAL_MINT + depositAmount);
    }

    function test_MultipleDeposits() public {
        uint256 deposit1 = 100 ether;
        uint256 deposit2 = 200 ether;

        // First deposit
        vm.prank(user1);
        vault.deposit(deposit1);

        // Second deposit
        vm.prank(user2);
        vault.deposit(deposit2);

        // Check calculations
        uint256 expectedShares1 = deposit1; // First deposit gets 1:1 ratio
        uint256 expectedShares2 = (deposit2 * deposit1) / (deposit1); // Second deposit gets proportional shares

        assertEq(vault.userShares(user1), expectedShares1);
        assertEq(vault.userShares(user2), expectedShares2);
        assertEq(vault.totalShares(), expectedShares1 + expectedShares2);
        assertEq(vault.totalAssets(), deposit1 + deposit2);
    }

    function test_ProcessRewards() public {
        uint256 depositAmount = 100 ether;
        uint256 rewardAmount = 10 ether;

        // Deposit first
        vm.prank(user1);
        vault.deposit(depositAmount);

        // Mint reward tokens to operator for testing
        aztecToken.mint(operator, rewardAmount);

        // Process rewards
        vm.prank(operator);
        vault.processRewards(rewardAmount);

        // Check rewards are added
        assertEq(vault.totalAssets(), depositAmount + rewardAmount);
        assertEq(vault.accumulatedRewards(), rewardAmount);
        assertEq(vault.withdrawalBuffer(), rewardAmount);
    }

    function test_WithdrawFromBuffer() public {
        uint256 depositAmount = 100 ether;
        uint256 rewardAmount = 100 ether; // Enough to cover withdrawal

        // Deposit and add sufficient rewards to buffer
        vm.prank(user1);
        vault.deposit(depositAmount);

        vm.prank(operator);
        vault.processRewards(rewardAmount);

        uint256 userShares = vault.userShares(user1);

        // Withdraw all shares
        vm.prank(user1);
        vault.withdraw(userShares);

        // Since buffer (100) < required assets (200), withdrawal gets queued
        (uint256 shares,, uint256 pendingWithdrawal) = vault.getUserBalance(user1);

        assertEq(shares, 0); // Shares withdrawn
        assertEq(pendingWithdrawal, depositAmount + rewardAmount); // 200 ether queued
        assertEq(aztecToken.balanceOf(user1), INITIAL_MINT - depositAmount); // No immediate transfer
        assertEq(vault.withdrawalBuffer(), rewardAmount); // Buffer unchanged
    }

    function test_PauseFunctionality() public {
        // Pause contract
        vm.prank(guardian);
        vault.emergencyPause();

        assertEq(vault.paused(), true);

        // Try to deposit while paused (should fail)
        vm.prank(user1);
        vm.expectRevert("Contract paused");
        vault.deposit(100 ether);

        // Unpause
        vm.prank(guardian);
        vault.emergencyUnpause();

        assertEq(vault.paused(), false);

        // Deposit should work now
        vm.prank(user1);
        vault.deposit(100 ether);
        assertEq(vault.userShares(user1), 100 ether);
    }

    function test_CalculateSharesAndAssets() public {
        // Test initial deposit
        uint256 assets = 100 ether;
        uint256 shares = vault.calculateShares(assets);
        assertEq(shares, assets);

        // Deposit to establish ratio
        vm.prank(user1);
        vault.deposit(assets);

        // Test calculations
        uint256 newAssets = 50 ether;
        uint256 newShares = vault.calculateShares(newAssets);
        uint256 expectedShares = (newAssets * assets) / assets;
        assertEq(newShares, expectedShares);

        // Test reverse calculation
        uint256 calculatedAssets = vault.calculateAssets(newShares);
        assertEq(calculatedAssets, newAssets);
    }
}
