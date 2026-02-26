// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { OllaGovernanceSetup } from "./OllaGovernanceSetup.t.sol";

/// @title OllaGovernanceTreasuryTest
/// @notice Tests for treasury address management on OllaGovernance.
contract OllaGovernanceTreasuryTest is OllaGovernanceSetup {
    /*//////////////////////////////////////////////////////////////
                          SET TREASURY
    //////////////////////////////////////////////////////////////*/

    function test_SetTreasury_ViaTimelock() external {
        address newTreasury = makeAddr("newTreasury");
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (newTreasury));

        // Schedule
        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        // Expect event on execute
        vm.expectEmit(true, true, false, true, address(gov));
        emit IOllaGovernance.TreasuryUpdated(treasuryAddr, newTreasury);

        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));

        assertEq(gov.treasury(), newTreasury, "treasury updated");
    }

    function test_RevertWhen_SetTreasury_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setTreasury(alice);
    }

    function test_RevertWhen_SetTreasury_ZeroAddress() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasury, (address(0)));

        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert();
        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                    TREASURY INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function test_Treasury_InitialValue() external view {
        assertEq(gov.treasury(), treasuryAddr, "initial treasury matches");
    }

    /*//////////////////////////////////////////////////////////////
                    TREASURY USED FOR FEES
    //////////////////////////////////////////////////////////////*/

    function test_Treasury_UsedByOllaCoreForInstantRedemptionFees() external {
        // Set instant redemption fee to 1%
        bytes memory feeData = abi.encodeCall(IOllaGovernance.setInstantRedemptionFeeBP, (100));
        _scheduleAndExecute(address(gov), feeData);

        // Deposit some assets
        uint256 depositAmount = 100 * DECIMALS;
        asset.mint(alice, depositAmount);
        vm.prank(alice);
        asset.approve(address(vault), depositAmount);
        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice, 0);

        // Perform instant redemption
        uint256 treasuryBalanceBefore = asset.balanceOf(treasuryAddr);
        vm.prank(alice);
        vault.redeem(shares, alice, 0);

        uint256 treasuryBalanceAfter = asset.balanceOf(treasuryAddr);
        assertGt(treasuryBalanceAfter, treasuryBalanceBefore, "treasury received fees");
    }
}
