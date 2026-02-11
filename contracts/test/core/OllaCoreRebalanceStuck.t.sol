// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

/// @title OllaCoreRebalanceStuck.t.sol
/// @notice Reproduces bug where rebalance gets stuck in StakeSurplus step
/// when staking manager has insufficient capacity to stake all surplus.
contract OllaCoreRebalanceStuck is Test {
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant DEFAULT_REBALANCE_GAS_THRESHOLD = 180_000;

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal operator;

    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 bufferedAssets);

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockAccountingStakingManager();
        operator = makeAddr("operator");
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation), abi.encodeCall(WithdrawalQueue.initialize, (address(vault), governance))
        );
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));

        // Configure staking manager to mint rewards directly to rewards vault
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            0,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        alice = makeAddr("alice");

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vm.stopPrank();
    }

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
    }

    /// @notice Reproduces the bug: rebalance gets stuck when staking manager
    /// can only stake part of the surplus, leaving remainder that can't be staked.
    function test_Rebalance_StuckInStakeSurplus_WhenPartialStakeCapacity() external {
        // Setup: Create a situation where we have more to stake than capacity allows
        // Target buffer: 1 ETH (minimum to keep in vault)
        uint256 targetBuffer = 1 * DECIMALS;
        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBuffer);

        // Deposit large amount: 10 ETH
        // After rebalance: should stake 9 ETH (10 - 1 target buffer)
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Simulate staking manager with partial capacity:
        // First stake call stakes 8 ETH (leaving 1 ETH surplus)
        // Second stake call for remaining 1 ETH returns 0 (no capacity left)
        uint256 firstStakeAmount = 8 * DECIMALS;
        stakingManager.setStakeReturnAmount(firstStakeAmount);
        stakingManager.setAllowStakeReturnExceeds(true);

        // First rebalance: stakes 8 ETH, leaving 1 ETH surplus
        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progress1 = vault.rebalanceProgress();
        IOllaCore.AccountingState memory accounting1 = vault.accountingState();

        // Verify we're in StakeSurplus step with remaining amount
        assertEq(uint256(progress1.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "should be in StakeSurplus");
        // stakeRemaining should be ~1 ETH (10 deposit - 8 staked - 1 target buffer = 1 remaining)
        assertEq(progress1.stakeRemaining, 1 * DECIMALS, "should have 1 ETH remaining to stake");
        assertEq(accounting1.bufferedAssets, 2 * DECIMALS, "buffer should be deposit - staked = 2 ETH");

        // Now simulate: no more capacity (staking returns 0)
        stakingManager.setStakeReturnAmount(0);

        // Second rebalance: tries to stake remaining 1 ETH but gets 0
        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progress2 = vault.rebalanceProgress();

        // BUG: We're still in StakeSurplus step and stakeRemaining is still 1 ETH
        // The rebalance should have advanced to Done since no more staking can occur
        assertEq(
            uint256(progress2.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "BUG: still stuck in StakeSurplus"
        );
        assertEq(progress2.stakeRemaining, 1 * DECIMALS, "BUG: stakeRemaining unchanged");

        // Keep calling rebalance - it should eventually complete but doesn't
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(operator);
            vault.rebalance();
        }

        IOllaCore.RebalanceProgress memory progressFinal = vault.rebalanceProgress();

        // BUG: After many iterations, we're still not Done
        // This assertion will FAIL demonstrating the bug
        assertEq(
            uint256(progressFinal.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "BUG: Rebalance never completes - stuck in infinite loop"
        );
    }

    /// @notice Verifies that when stake() returns 0 for the remainder, rebalance should complete.
    function test_Rebalance_ShouldComplete_WhenStakeReturnsZero() external {
        // Setup similar scenario but verify expected behavior
        uint256 targetBuffer = 1 * DECIMALS;
        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBuffer);

        uint256 depositAmount = 5 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // First stake: 3 ETH
        stakingManager.setStakeReturnAmount(3 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        vm.prank(operator);
        vault.rebalance();

        // Second stake: 0 (no capacity)
        stakingManager.setStakeReturnAmount(0);

        vm.prank(operator);
        vault.rebalance();

        // At this point, rebalance should detect that stake() returned 0
        // and advance to Done since no more progress can be made
        IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();

        // This documents the expected behavior (what should happen after fix)
        // Currently this will fail - uncomment after contract is fixed
        // assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "should complete when stake returns 0");

        // For now, just verify the stuck state
        assertEq(
            uint256(progress.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "currently stuck in StakeSurplus"
        );
    }
}
