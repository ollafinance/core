// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerGasThresholdTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                         GAS THRESHOLD TESTS
    //////////////////////////////////////////////////////////////*/

    event GasThresholdUpdated(uint256 indexed oldValue, uint256 indexed newValue);

    function test_SetGasThreshold_EmitsEvent() external {
        uint256 newThreshold = 180_000;

        vm.expectEmit(true, true, false, true);
        emit GasThresholdUpdated(50_000, newThreshold);

        vm.prank(core);
        stakingManager.setGasThreshold(newThreshold);
    }

    function test_SetGasThreshold_EmitsPreviousValueOnUpdate() external {
        uint256 firstThreshold = 120_000;
        uint256 secondThreshold = 240_000;

        vm.prank(core);
        stakingManager.setGasThreshold(firstThreshold);

        vm.expectEmit(true, true, false, true);
        emit GasThresholdUpdated(firstThreshold, secondThreshold);

        vm.prank(core);
        stakingManager.setGasThreshold(secondThreshold);
    }

    function test_RevertWhen_SetGasThreshold_Zero() external {
        vm.expectRevert(IStakingManager.StakingManager__ZeroAmount.selector);

        vm.prank(core);
        stakingManager.setGasThreshold(0);
    }

    function test_RevertWhen_SetGasThreshold_NotCore() external {
        vm.expectRevert(abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, alice));

        vm.prank(alice);
        stakingManager.setGasThreshold(100_000);
    }
}
