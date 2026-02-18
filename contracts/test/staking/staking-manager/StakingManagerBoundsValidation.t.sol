// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";
import { StakingManagerBaseTest } from "test/staking/staking-manager/StakingManagerBase.t.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

contract StakingManagerBoundsValidationTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                        ATTESTER STATE MAX AGE
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetAttesterStateMaxAge_BelowMin() public {
        uint256 belowMin = stakingManager.MIN_ATTESTER_STATE_MAX_AGE() - 1; // 3599
        vm.prank(defaultAdmin);
        vm.expectRevert(IStakingManager.StakingManager__InvalidParameter.selector);
        stakingManager.setAttesterStateMaxAge(belowMin);
    }

    function test_RevertWhen_SetAttesterStateMaxAge_AboveMax() public {
        uint256 aboveMax = stakingManager.MAX_ATTESTER_STATE_MAX_AGE() + 1; // 48 hours + 1
        vm.prank(defaultAdmin);
        vm.expectRevert(IStakingManager.StakingManager__InvalidParameter.selector);
        stakingManager.setAttesterStateMaxAge(aboveMax);
    }

    function test_SetAttesterStateMaxAge_AtMin() public {
        uint256 minAge = stakingManager.MIN_ATTESTER_STATE_MAX_AGE(); // 1 hour
        vm.prank(defaultAdmin);
        stakingManager.setAttesterStateMaxAge(minAge);

        (, uint256 maxAge,) = stakingManager.getAttesterStateLiveness();
        assertEq(maxAge, minAge);
    }

    function test_SetAttesterStateMaxAge_AtMax() public {
        uint256 maxAgeVal = stakingManager.MAX_ATTESTER_STATE_MAX_AGE(); // 48 hours
        vm.prank(defaultAdmin);
        stakingManager.setAttesterStateMaxAge(maxAgeVal);

        (, uint256 maxAge,) = stakingManager.getAttesterStateLiveness();
        assertEq(maxAge, maxAgeVal);
    }

    function testFuzz_SetAttesterStateMaxAge_ValidRange(uint256 value) public {
        uint256 minAge = stakingManager.MIN_ATTESTER_STATE_MAX_AGE();
        uint256 maxAgeVal = stakingManager.MAX_ATTESTER_STATE_MAX_AGE();
        value = bound(value, minAge, maxAgeVal);

        vm.prank(defaultAdmin);
        stakingManager.setAttesterStateMaxAge(value);

        (, uint256 maxAge,) = stakingManager.getAttesterStateLiveness();
        assertEq(maxAge, value);
    }

    function testFuzz_SetAttesterStateMaxAge_InvalidBelowMin(uint256 value) public {
        uint256 minAge = stakingManager.MIN_ATTESTER_STATE_MAX_AGE();
        value = bound(value, 0, minAge - 1);

        vm.prank(defaultAdmin);
        vm.expectRevert(IStakingManager.StakingManager__InvalidParameter.selector);
        stakingManager.setAttesterStateMaxAge(value);
    }

    function testFuzz_SetAttesterStateMaxAge_InvalidAboveMax(uint256 value) public {
        uint256 maxAgeVal = stakingManager.MAX_ATTESTER_STATE_MAX_AGE();
        value = bound(value, maxAgeVal + 1, type(uint256).max);

        vm.prank(defaultAdmin);
        vm.expectRevert(IStakingManager.StakingManager__InvalidParameter.selector);
        stakingManager.setAttesterStateMaxAge(value);
    }
}
