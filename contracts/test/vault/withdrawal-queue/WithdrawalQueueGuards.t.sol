// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { MockFinalizationCallback } from "src/vault/mocks/MockFinalizationCallback.sol";

contract WithdrawalQueueGuardsTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant NO_SLASH_RATE = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    WithdrawalQueue internal queue;
    address internal vault;
    address internal admin;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        // Real WithdrawalQueue invokes vault.onWithdrawalFinalized per finalize, so the
        // configured `vault` must be a contract implementing IFinalizationCallback.
        vault = address(new MockFinalizationCallback());
        vm.label(vault, "vault");
        admin = makeAddr("admin");
        alice = makeAddr("alice");

        WithdrawalQueue implementation = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        queue = WithdrawalQueue(address(proxy));
        queue.initialize(vault, admin, 50_000);
    }

    /*//////////////////////////////////////////////////////////////
                        ONLY-VAULT MODIFIER
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NonVaultCallsRequestWithdrawal() external {
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault.selector, alice));
        vm.prank(alice);
        queue.requestWithdrawal(alice, 1 ether, 1 ether, 1e18);
    }

    function test_RevertWhen_NonVaultCallsFinalizeWithdrawals() external {
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault.selector, alice));
        vm.prank(alice);
        queue.finalizeWithdrawals(1 ether, NO_SLASH_RATE, type(uint256).max);
    }

    function test_RevertWhen_NonVaultCallsClaimWithdrawal() external {
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault.selector, alice));
        vm.prank(alice);
        queue.claimWithdrawal(1);
    }

    /*//////////////////////////////////////////////////////////////
                      INITIALIZE ZERO-ADDRESS GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_InitializeWithZeroVault() external {
        WithdrawalQueue impl = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        WithdrawalQueue freshQueue = WithdrawalQueue(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__ZeroAddress.selector, "vault_"));
        freshQueue.initialize(address(0), admin, 50_000);
    }

    function test_RevertWhen_InitializeWithZeroAdmin() external {
        WithdrawalQueue impl = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        WithdrawalQueue freshQueue = WithdrawalQueue(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__ZeroAddress.selector, "admin_"));
        freshQueue.initialize(vault, address(0), 50_000);
    }

    /*//////////////////////////////////////////////////////////////
                   REQUEST WITHDRAWAL ZERO RECIPIENT
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestWithdrawalZeroRecipient() external {
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__ZeroAddress.selector, "recipient"));
        vm.prank(vault);
        queue.requestWithdrawal(address(0), 1 ether, 1 ether, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                   CLAIM NON-EXISTENT REQUEST
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ClaimNonExistentRequest() external {
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__InvalidRequest.selector, uint256(999)));
        vm.prank(vault);
        queue.claimWithdrawal(999);
    }

    /*//////////////////////////////////////////////////////////////
                   GET REQUEST NON-EXISTENT
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_GetNonExistentRequest() external {
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__InvalidRequest.selector, uint256(999)));
        queue.getRequest(999);
    }
}
