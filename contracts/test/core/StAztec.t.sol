// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "@forge-std/Test.sol";

import { StAztec } from "src/core/StAztec.sol";

contract StAztecTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);

    uint256 internal constant DECIMALS = 1e18;

    StAztec internal token;
    address internal core;
    address internal alice;
    address internal bob;
    address internal charlie;

    function setUp() external {
        core = makeAddr("core");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        token = new StAztec(core);
    }

    function test_ERC20Compliance() external {
        uint256 mintAmount = 100 * DECIMALS;

        vm.prank(core);
        token.mint(alice, mintAmount);

        vm.prank(alice);
        token.transfer(bob, 40 * DECIMALS);

        assertEq(token.balanceOf(alice), 60 * DECIMALS, "alice balance after transfer");
        assertEq(token.balanceOf(bob), 40 * DECIMALS, "bob balance after transfer");

        vm.prank(alice);
        token.approve(charlie, 30 * DECIMALS);

        vm.prank(charlie);
        token.transferFrom(alice, bob, 30 * DECIMALS);

        assertEq(token.balanceOf(alice), 30 * DECIMALS, "alice balance after transferFrom");
        assertEq(token.balanceOf(bob), 70 * DECIMALS, "bob balance after transferFrom");
        assertEq(token.allowance(alice, charlie), 0, "allowance after transferFrom");
        assertEq(token.decimals(), 18, "decimals");
    }

    function test_OnlyAuthorizedCanMint() external {
        vm.expectRevert(abi.encodeWithSelector(StAztec.StAztecUnauthorized.selector, alice));
        vm.prank(alice);
        token.mint(alice, 1 * DECIMALS);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(0), alice, 10 * DECIMALS);

        vm.prank(core);
        token.mint(alice, 10 * DECIMALS);

        assertEq(token.balanceOf(alice), 10 * DECIMALS, "minted balance");
    }

    function test_OnlyAuthorizedCanBurn() external {
        vm.prank(core);
        token.mint(alice, 10 * DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(StAztec.StAztecUnauthorized.selector, bob));
        vm.prank(bob);
        token.burn(alice, 1 * DECIMALS);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(alice, address(0), 4 * DECIMALS);

        vm.prank(core);
        token.burn(alice, 4 * DECIMALS);

        assertEq(token.balanceOf(alice), 6 * DECIMALS, "burned balance");
    }

    function test_TotalSupplyEqualsBalances() external {
        vm.prank(core);
        token.mint(alice, 25 * DECIMALS);

        vm.prank(core);
        token.mint(bob, 15 * DECIMALS);

        vm.prank(core);
        token.burn(alice, 5 * DECIMALS);

        uint256 supply = token.totalSupply();
        uint256 sumBalances = token.balanceOf(alice) + token.balanceOf(bob);

        assertEq(supply, sumBalances, "supply equals balances");
    }

    function testFuzz_TransferPreservesTotalSupply(uint96 amount) external {
        amount = uint96(bound(amount, 1, type(uint96).max));

        vm.prank(core);
        token.mint(alice, amount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, amount / 2);

        assertEq(token.totalSupply(), supplyBefore, "total supply unchanged");
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), supplyBefore, "balances sum to supply");
    }

    function testFuzz_ApproveAndTransferFrom(uint96 mintAmount, uint96 spendAmount) external {
        mintAmount = uint96(bound(mintAmount, 1, type(uint96).max));
        spendAmount = uint96(bound(spendAmount, 0, mintAmount));

        vm.prank(core);
        token.mint(alice, mintAmount);

        vm.prank(alice);
        token.approve(charlie, spendAmount);

        vm.prank(charlie);
        token.transferFrom(alice, bob, spendAmount);

        assertEq(token.balanceOf(alice), mintAmount - spendAmount, "alice balance after transferFrom");
        assertEq(token.balanceOf(bob), spendAmount, "bob balance after transferFrom");
        assertEq(token.allowance(alice, charlie), 0, "allowance after transferFrom");
    }

    function testFuzz_UnauthorizedMintBurnReverts(address attacker, uint96 amount) external {
        vm.assume(attacker != core);
        amount = uint96(bound(amount, 1, type(uint96).max));

        vm.expectRevert(abi.encodeWithSelector(StAztec.StAztecUnauthorized.selector, attacker));
        vm.prank(attacker);
        token.mint(attacker, amount);

        vm.prank(core);
        token.mint(alice, amount);

        vm.expectRevert(abi.encodeWithSelector(StAztec.StAztecUnauthorized.selector, attacker));
        vm.prank(attacker);
        token.burn(alice, amount);
    }
}
