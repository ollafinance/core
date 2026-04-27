// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { OllaGovernanceSetup } from "./OllaGovernanceSetup.t.sol";

/// @title OllaGovernancePassthroughsTest
/// @notice Tests that OllaCore parameter passthroughs work via the timelock
///         and revert when called directly.
contract OllaGovernancePassthroughsTest is OllaGovernanceSetup {
    /*//////////////////////////////////////////////////////////////
                       setProtocolFeeBP
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFeeBP_ViaTimelock() external {
        uint256 newFee = 1_000;
        bytes memory data = abi.encodeCall(IOllaGovernance.setProtocolFeeBP, (newFee));
        _scheduleAndExecute(address(gov), data);
        assertEq(core.protocolFeeBP(), newFee, "protocol fee updated");
    }

    function test_RevertWhen_SetProtocolFeeBP_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setProtocolFeeBP(1_000);
    }

    /*//////////////////////////////////////////////////////////////
                     setTreasuryFeeSplitBP
    //////////////////////////////////////////////////////////////*/

    function test_SetTreasuryFeeSplitBP_ViaTimelock() external {
        uint256 newSplit = 7_000;
        bytes memory data = abi.encodeCall(IOllaGovernance.setTreasuryFeeSplitBP, (newSplit));
        _scheduleAndExecute(address(gov), data);
        assertEq(core.treasuryFeeSplitBP(), newSplit, "treasury split updated");
    }

    function test_RevertWhen_SetTreasuryFeeSplitBP_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setTreasuryFeeSplitBP(7_000);
    }

    /*//////////////////////////////////////////////////////////////
                     setTargetBufferedAssets
    //////////////////////////////////////////////////////////////*/

    function test_SetTargetBufferedAssets_ViaTimelock() external {
        uint256 newBuffer = 100 * DECIMALS;
        bytes memory data = abi.encodeCall(IOllaGovernance.setTargetBufferedAssets, (newBuffer));
        _scheduleAndExecute(address(gov), data);
        assertEq(core.targetBufferedAssets(), newBuffer, "target buffer updated");
    }

    function test_RevertWhen_SetTargetBufferedAssets_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setTargetBufferedAssets(100 * DECIMALS);
    }

    /*//////////////////////////////////////////////////////////////
                     setRebalanceGasThreshold
    //////////////////////////////////////////////////////////////*/

    function test_SetRebalanceGasThreshold_ViaTimelock() external {
        uint256 newThreshold = 200_000;
        bytes memory data = abi.encodeCall(IOllaGovernance.setRebalanceGasThreshold, (newThreshold));
        _scheduleAndExecute(address(gov), data);
        assertEq(core.rebalanceGasThreshold(), newThreshold, "gas threshold updated");
    }

    function test_RevertWhen_SetRebalanceGasThreshold_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setRebalanceGasThreshold(200_000);
    }

    /*//////////////////////////////////////////////////////////////
                         setSafetyModule
    //////////////////////////////////////////////////////////////*/

    function test_SetSafetyModule_ViaTimelock() external {
        address newSM = address(new MockSafetyModuleStub(address(core), address(vault)));
        bytes memory data = abi.encodeCall(IOllaGovernance.setSafetyModule, (newSM));
        _scheduleAndExecute(address(gov), data);
        assertEq(core.safetyModule(), newSM, "safety module updated");
    }

    function test_RevertWhen_SetSafetyModule_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setSafetyModule(alice);
    }

    /*//////////////////////////////////////////////////////////////
                       setRebalanceCooldown
    //////////////////////////////////////////////////////////////*/

    function test_SetRebalanceCooldown_ViaTimelock() external {
        uint256 newCooldown = 2 hours;
        bytes memory data = abi.encodeCall(IOllaGovernance.setRebalanceCooldown, (newCooldown));
        _scheduleAndExecute(address(gov), data);
        assertEq(core.rebalanceCooldown(), newCooldown, "cooldown updated");
    }

    function test_RevertWhen_SetRebalanceCooldown_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setRebalanceCooldown(2 hours);
    }

    /*//////////////////////////////////////////////////////////////
                       recoverStAztec
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RecoverStAztec_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.recoverStAztec(alice, 1);
    }

    /*//////////////////////////////////////////////////////////////
                   reconcileBufferedAssets
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ReconcileBufferedAssets_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.reconcileBufferedAssets();
    }

    /*//////////////////////////////////////////////////////////////
                 SAFETY MODULE PASSTHROUGHS
    //////////////////////////////////////////////////////////////*/

    function test_SetDepositCap_ViaTimelock() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setDepositCap, (1_000 * DECIMALS));
        // Should not revert -- MockSafetyModule accepts any cap
        _scheduleAndExecute(address(gov), data);
    }

    function test_RevertWhen_SetDepositCap_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setDepositCap(1_000 * DECIMALS);
    }

    function test_SetWithdrawalMinimum_ViaTimelock() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setWithdrawalMinimum, (1 * DECIMALS));
        _scheduleAndExecute(address(gov), data);
    }

    function test_RevertWhen_SetWithdrawalMinimum_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setWithdrawalMinimum(1 * DECIMALS);
    }

    function test_SetMinRateDropBps_ViaTimelock() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setMinRateDropBps, (500));
        _scheduleAndExecute(address(gov), data);
    }

    function test_RevertWhen_SetMinRateDropBps_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setMinRateDropBps(500);
    }

    function test_SetMaxQueueRatioBps_ViaTimelock() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setMaxQueueRatioBps, (2_000));
        _scheduleAndExecute(address(gov), data);
    }

    function test_RevertWhen_SetMaxQueueRatioBps_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setMaxQueueRatioBps(2_000);
    }

    function test_SetMaxAccountingDelay_ViaTimelock() external {
        bytes memory data = abi.encodeCall(IOllaGovernance.setMaxAccountingDelay, (12 hours));
        _scheduleAndExecute(address(gov), data);
    }

    function test_RevertWhen_SetMaxAccountingDelay_DirectCall() external {
        vm.expectRevert(IOllaGovernance.OllaGovernance__OnlySelf.selector);
        vm.prank(admin);
        gov.setMaxAccountingDelay(12 hours);
    }
}

/// @notice Tiny safety-module stub that returns the correct CORE address.
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

contract MockSafetyModuleStub {
    address private immutable _core;
    address private immutable _vault;

    constructor(address core_, address vault_) {
        _core = core_;
        _vault = vault_;
    }

    function CORE() external view returns (address) {
        return _core;
    }

    function VAULT() external view returns (address) {
        return _vault;
    }

    // Satisfy ISafetyModule interface calls made by OllaCore.setSafetyModule validation:
    function isPaused() external pure returns (bool) {
        return false;
    }

    function isDepositPaused() external pure returns (bool) {
        return false;
    }

    function checkDepositAllowed(uint256, uint256) external pure returns (bool) {
        return true;
    }

    function checkWithdrawalMinimum(uint256) external pure { }
    function checkRateDrop(uint256, uint256) external pure { }
    function checkQueueRatio(uint256, uint256) external pure { }
    function checkAccountingLiveness() external pure { }
    function setDepositCap(uint256) external pure { }
    function setWithdrawalMinimum(uint256) external pure { }
    function setMinRateDropBps(uint256) external pure { }
    function setRateHighWaterMark(uint256) external pure { }
    function setMaxQueueRatioBps(uint256) external pure { }
    function setMaxAccountingDelay(uint256) external pure { }
    function setLatestAccountingTimestamp(uint256) external pure { }
    function pause() external pure { }
    function unpause() external pure { }
}
