// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

contract WithdrawalQueueGasThresholdTest is Test {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event GasThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    WithdrawalQueue internal queue;
    address internal vault;
    address internal admin;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        vault = makeAddr("vault");
        admin = makeAddr("admin");

        WithdrawalQueue implementation = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        queue = WithdrawalQueue(address(proxy));
        queue.initialize(vault, admin, 50_000);
    }

    /*//////////////////////////////////////////////////////////////
                    INITIALIZE GAS THRESHOLD
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsGasThreshold() public view {
        assertEq(queue.gasThreshold(), 50_000, "gas threshold should be set during init");
    }

    /*//////////////////////////////////////////////////////////////
                       SET GAS THRESHOLD
    //////////////////////////////////////////////////////////////*/

    function test_SetGasThreshold_UpdatesValue() public {
        vm.expectEmit(false, false, false, true, address(queue));
        emit GasThresholdUpdated(50_000, 100_000);

        vm.prank(vault);
        queue.setGasThreshold(100_000);

        assertEq(queue.gasThreshold(), 100_000, "gas threshold should be updated");
    }

    function test_RevertWhen_SetGasThreshold_NotVault() public {
        address notVault = makeAddr("notVault");

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault.selector, notVault));
        vm.prank(notVault);
        queue.setGasThreshold(100_000);
    }

    function test_RevertWhen_SetGasThreshold_ZeroThreshold() public {
        vm.expectRevert(IWithdrawalQueue.WithdrawalQueue__InvalidParameter.selector);
        vm.prank(vault);
        queue.setGasThreshold(0);
    }

    function test_RevertWhen_Initialize_ZeroGasThreshold() public {
        WithdrawalQueue implementation = new WithdrawalQueue();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        WithdrawalQueue q = WithdrawalQueue(address(proxy));

        vm.expectRevert(IWithdrawalQueue.WithdrawalQueue__InvalidParameter.selector);
        q.initialize(vault, admin, 0);
    }

    function test_RevertWhen_SetGasThreshold_ExceedsMax() public {
        vm.expectRevert(IWithdrawalQueue.WithdrawalQueue__InvalidParameter.selector);
        vm.prank(vault);
        queue.setGasThreshold(30_000_001);
    }

    function test_SetGasThreshold_AtMax() public {
        vm.expectEmit(false, false, false, true, address(queue));
        emit GasThresholdUpdated(50_000, 30_000_000);

        vm.prank(vault);
        queue.setGasThreshold(30_000_000);

        assertEq(queue.gasThreshold(), 30_000_000, "gas threshold should be set to max");
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW FUNCTION
    //////////////////////////////////////////////////////////////*/

    function test_GasThreshold_ReturnsValue() public {
        vm.prank(vault);
        queue.setGasThreshold(200_000);

        assertEq(queue.gasThreshold(), 200_000, "gasThreshold() should return updated value");
    }
}
