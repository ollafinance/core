// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC20Permit } from "@oz/token/ERC20/extensions/ERC20Permit.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { StAztec } from "src/core/StAztec.sol";

contract StAztecTest is Test {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 value);

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    StAztec internal token;
    address internal core;
    address internal alice;
    address internal bob;
    address internal charlie;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        core = makeAddr("core");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // In this unit test we set `core` as both governance and the authorized core.
        token = new StAztec(core, core);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _buildPermitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    /*//////////////////////////////////////////////////////////////
                          ERC20 BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    function test_ERC20Compliance() external {
        uint256 mintAmount = 100 * DECIMALS;

        vm.prank(core);
        token.mint(alice, mintAmount);

        vm.prank(alice);
        bool transferSuccess = token.transfer(bob, 40 * DECIMALS);
        assertTrue(transferSuccess, "transfer should succeed");

        assertEq(token.balanceOf(alice), 60 * DECIMALS, "alice balance after transfer");
        assertEq(token.balanceOf(bob), 40 * DECIMALS, "bob balance after transfer");

        vm.prank(alice);
        token.approve(charlie, 30 * DECIMALS);

        vm.prank(charlie);
        bool transferFromSuccess = token.transferFrom(alice, bob, 30 * DECIMALS);
        assertTrue(transferFromSuccess, "transferFrom should succeed");

        assertEq(token.balanceOf(alice), 30 * DECIMALS, "alice balance after transferFrom");
        assertEq(token.balanceOf(bob), 70 * DECIMALS, "bob balance after transferFrom");
        assertEq(token.allowance(alice, charlie), 0, "allowance after transferFrom");
        assertEq(token.decimals(), 18, "decimals");
    }

    /*//////////////////////////////////////////////////////////////
                          PERMIT FUNCTION
    //////////////////////////////////////////////////////////////*/

    function test_PermitSetsAllowance() external {
        uint256 ownerKey = 0xA11CE;
        address owner = vm.addr(ownerKey);
        uint256 value = 12 * DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = token.nonces(owner);

        bytes32 digest = _buildPermitDigest(owner, bob, value, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, bob, value, deadline, v, r, s);

        assertEq(token.allowance(owner, bob), value, "permit allowance");
        assertEq(token.nonces(owner), nonce + 1, "permit nonce incremented");
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_PermitExpired() external {
        uint256 ownerKey = 0xB0B;
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp - 1;
        uint256 nonce = token.nonces(owner);

        bytes32 digest = _buildPermitDigest(owner, bob, 1, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, bob, 1, deadline, v, r, s);
    }

    function test_RevertWhen_PermitInvalidSigner() external {
        uint256 ownerKey = 0xA11CE;
        uint256 attackerKey = 0xBADC0DE;
        address owner = vm.addr(ownerKey);
        address attacker = vm.addr(attackerKey);
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = token.nonces(owner);

        bytes32 digest = _buildPermitDigest(owner, bob, 5, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerKey, digest);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, attacker, owner));
        token.permit(owner, bob, 5, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                         AUTHORIZATION FLOW
    //////////////////////////////////////////////////////////////*/

    function test_OnlyAuthorizedCanMint() external {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.MINTER_ROLE())
        );
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

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, token.BURNER_ROLE())
        );
        vm.prank(bob);
        token.burn(alice, 1 * DECIMALS);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(alice, address(0), 4 * DECIMALS);

        vm.prank(core);
        token.burn(alice, 4 * DECIMALS);

        assertEq(token.balanceOf(alice), 6 * DECIMALS, "burned balance");
    }

    /*//////////////////////////////////////////////////////////////
                         SUPPLY INVARIANTS
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PermitUpdatesAllowance(uint96 value, uint32 deadlineOffset) external {
        uint256 ownerKey = 0xA11CE;
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp + uint256(bound(deadlineOffset, 1, 30 days));

        value = uint96(bound(value, 0, type(uint96).max));

        uint256 nonce = token.nonces(owner);
        bytes32 digest = _buildPermitDigest(owner, bob, value, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, bob, value, deadline, v, r, s);

        assertEq(token.allowance(owner, bob), value, "permit allowance");
        assertEq(token.nonces(owner), nonce + 1, "permit nonce incremented");
    }

    function testFuzz_TransferPreservesTotalSupply(uint96 amount) external {
        amount = uint96(bound(amount, 1, type(uint96).max));

        vm.prank(core);
        token.mint(alice, amount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        bool fuzzTransferSuccess = token.transfer(bob, amount / 2);
        assertTrue(fuzzTransferSuccess, "transfer should succeed");

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
        bool fuzzTransferFromSuccess = token.transferFrom(alice, bob, spendAmount);
        assertTrue(fuzzTransferFromSuccess, "transferFrom should succeed");

        assertEq(token.balanceOf(alice), mintAmount - spendAmount, "alice balance after transferFrom");
        assertEq(token.balanceOf(bob), spendAmount, "bob balance after transferFrom");
        assertEq(token.allowance(alice, charlie), 0, "allowance after transferFrom");
    }

    function testFuzz_UnauthorizedMintBurnReverts(address attacker, uint96 amount) external {
        vm.assume(attacker != core);
        amount = uint96(bound(amount, 1, type(uint96).max));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, token.MINTER_ROLE()
            )
        );
        vm.prank(attacker);
        token.mint(attacker, amount);

        vm.prank(core);
        token.mint(alice, amount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, token.BURNER_ROLE()
            )
        );
        vm.prank(attacker);
        token.burn(alice, amount);
    }
}
