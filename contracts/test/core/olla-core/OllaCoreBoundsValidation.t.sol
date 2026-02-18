// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";

contract OllaCoreBoundsValidationTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event InstantRedemptionFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);
    event RebalanceGasThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant INITIAL_PROTOCOL_FEE_BP = 500;
    uint256 internal constant INITIAL_TREASURY_SPLIT_BP = 5_000;

    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    address internal governance;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    MockWithdrawalQueue internal withdrawalQueue;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        rewardsVault = new MockRewardsVault(asset, address(coreImplementation));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        withdrawalQueue = new MockWithdrawalQueue();

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            INITIAL_PROTOCOL_FEE_BP,
            INITIAL_TREASURY_SPLIT_BP,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );
    }

    /*//////////////////////////////////////////////////////////////
                  INSTANT REDEMPTION FEE — REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetInstantRedemptionFeeBP_ExceedsMax() external {
        uint256 aboveMax = vault.MAX_INSTANT_REDEMPTION_FEE_BP() + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, aboveMax));
        vault.setInstantRedemptionFeeBP(aboveMax);
    }

    /*//////////////////////////////////////////////////////////////
                  INSTANT REDEMPTION FEE — BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetInstantRedemptionFeeBP_AllowsZero() external {
        vm.prank(governance);
        vault.setInstantRedemptionFeeBP(0);
        assertEq(vault.instantRedemptionFeeBP(), 0, "instant redemption fee set to zero");
    }

    function test_SetInstantRedemptionFeeBP_AllowsMax() external {
        uint256 maxFee = vault.MAX_INSTANT_REDEMPTION_FEE_BP();
        vm.prank(governance);
        vault.setInstantRedemptionFeeBP(maxFee);
        assertEq(vault.instantRedemptionFeeBP(), maxFee, "instant redemption fee set to max");
    }

    /*//////////////////////////////////////////////////////////////
                  INSTANT REDEMPTION FEE — FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetInstantRedemptionFeeBP_ValidRange(uint256 newFeeBP) external {
        uint256 maxFee = vault.MAX_INSTANT_REDEMPTION_FEE_BP();
        newFeeBP = bound(newFeeBP, 0, maxFee);

        uint256 oldFeeBP = vault.instantRedemptionFeeBP();

        vm.expectEmit(true, true, true, true, address(vault));
        emit InstantRedemptionFeeUpdated(oldFeeBP, newFeeBP);

        vm.prank(governance);
        vault.setInstantRedemptionFeeBP(newFeeBP);

        assertEq(vault.instantRedemptionFeeBP(), newFeeBP, "instant redemption fee fuzz");
    }

    function testFuzz_SetInstantRedemptionFeeBP_InvalidRange(uint256 newFeeBP) external {
        uint256 maxFee = vault.MAX_INSTANT_REDEMPTION_FEE_BP();
        newFeeBP = bound(newFeeBP, maxFee + 1, type(uint256).max);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, newFeeBP));
        vault.setInstantRedemptionFeeBP(newFeeBP);
    }

    /*//////////////////////////////////////////////////////////////
                REBALANCE GAS THRESHOLD — REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetRebalanceGasThreshold_ExceedsMax() external {
        uint256 aboveMax = vault.MAX_REBALANCE_GAS_THRESHOLD() + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidGasThreshold.selector, aboveMax));
        vault.setRebalanceGasThreshold(aboveMax);
    }

    function test_RevertWhen_SetRebalanceGasThreshold_BelowMin() external {
        uint256 belowMin = vault.MIN_REBALANCE_GAS_THRESHOLD() - 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidGasThreshold.selector, belowMin));
        vault.setRebalanceGasThreshold(belowMin);
    }

    /*//////////////////////////////////////////////////////////////
                REBALANCE GAS THRESHOLD — BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetRebalanceGasThreshold_AllowsMin() external {
        uint256 minThreshold = vault.MIN_REBALANCE_GAS_THRESHOLD();
        vm.prank(governance);
        vault.setRebalanceGasThreshold(minThreshold);
        assertEq(vault.rebalanceGasThreshold(), minThreshold, "gas threshold set to min");
    }

    function test_SetRebalanceGasThreshold_AllowsMax() external {
        uint256 maxThreshold = vault.MAX_REBALANCE_GAS_THRESHOLD();
        vm.prank(governance);
        vault.setRebalanceGasThreshold(maxThreshold);
        assertEq(vault.rebalanceGasThreshold(), maxThreshold, "gas threshold set to max");
    }

    /*//////////////////////////////////////////////////////////////
                REBALANCE GAS THRESHOLD — FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetRebalanceGasThreshold_ValidRange(uint256 newThreshold) external {
        uint256 minThreshold = vault.MIN_REBALANCE_GAS_THRESHOLD();
        uint256 maxThreshold = vault.MAX_REBALANCE_GAS_THRESHOLD();
        newThreshold = bound(newThreshold, minThreshold, maxThreshold);

        uint256 oldThreshold = vault.rebalanceGasThreshold();

        vm.expectEmit(true, true, true, true, address(vault));
        emit RebalanceGasThresholdUpdated(oldThreshold, newThreshold);

        vm.prank(governance);
        vault.setRebalanceGasThreshold(newThreshold);

        assertEq(vault.rebalanceGasThreshold(), newThreshold, "gas threshold fuzz");
    }

    function testFuzz_SetRebalanceGasThreshold_InvalidRange_AboveMax(uint256 newThreshold) external {
        uint256 maxThreshold = vault.MAX_REBALANCE_GAS_THRESHOLD();
        newThreshold = bound(newThreshold, maxThreshold + 1, type(uint256).max);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidGasThreshold.selector, newThreshold));
        vault.setRebalanceGasThreshold(newThreshold);
    }

    function testFuzz_SetRebalanceGasThreshold_InvalidRange_BelowMin(uint256 newThreshold) external {
        uint256 minThreshold = vault.MIN_REBALANCE_GAS_THRESHOLD();
        newThreshold = bound(newThreshold, 0, minThreshold - 1);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidGasThreshold.selector, newThreshold));
        vault.setRebalanceGasThreshold(newThreshold);
    }
}
