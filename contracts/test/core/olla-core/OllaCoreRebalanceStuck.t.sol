// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, console } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaCoreRebalanceStuck.t.sol
/// @notice Reproduces bug where rebalance gets stuck in StakeSurplus step
/// when staking manager has insufficient capacity to stake all surplus.
contract OllaCoreRebalanceStuck is Test {
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant DEFAULT_REBALANCE_GAS_THRESHOLD = 180_000;

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal operator;

    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 bufferedAssets);

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        operator = makeAddr("operator");
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation),
            abi.encodeCall(WithdrawalQueue.initialize, (address(vault), governance, 180_000))
        );
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        // Configure staking manager to mint rewards directly to rewards vault
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");

        vm.warp(block.timestamp + 1 hours);
    }

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
    }

    /// @notice Reproduces the bug: rebalance gets stuck when staking manager
    /// can only stake part of the surplus, leaving remainder that can't be staked.
    /// This matches the mock-loop scenario: target buffer = 0, 200k deposit.
    function test_Rebalance_StuckInStakeSurplus_WhenPartialStakeCapacity() external {
        // Setup to match mock-loop scenario: target buffer = 0
        uint256 targetBuffer = 0;
        vm.prank(governance);
        core.setTargetBufferedAssets(targetBuffer);

        // Deposit 200k ETH (like mock-loop)
        uint256 depositAmount = 200_000 * DECIMALS;
        _performDeposit(alice, depositAmount);

        console.log("=== INITIAL STATE ===");
        console.log("Target buffer: 0 (all assets should be staked)");
        console.log("Deposit amount: 200000000000000000000000 (200k ETH)");

        // Simulate partial stake capacity: staking manager can only stake partial amounts
        // First call: stake 199,998 ETH (leaving 2 ETH)
        stakingManager.setStakeReturnAmount(199_998 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        console.log("\n=== FIRST REBALANCE ===");
        console.log("Setting stake return to: 199998 ETH");

        vm.prank(operator);
        (,, uint256 staked1,) = core.rebalance();
        console.log("Staked:", staked1);

        IOllaCore.RebalanceProgress memory progress1 = core.rebalanceProgress();
        IOllaCore.AccountingState memory accounting1 = core.accountingState();

        console.log("After first rebalance:");
        console.log("  Step:", uint256(progress1.step), "(4=StakeSurplus, 5=Done)");
        console.log("  stakeRemaining:", progress1.stakeRemaining);
        console.log("  bufferedAssets:", vault.bufferedAssets());
        console.log("  stakedPrincipal:", accounting1.stakedPrincipal);

        // Now set stake to return 0 (no more capacity)
        stakingManager.setStakeReturnAmount(0);
        console.log("\n=== SET STAKE RETURN TO 0 ===");

        console.log("\n=== CALLING REBALANCE 5 TIMES ===");
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(operator);
            (,, uint256 staked,) = core.rebalance();
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            console.log("Rebalance", i + 2, ":");
            console.log("  Staked:", staked);
            console.log("  Step:", uint256(p.step));
            console.log("  stakeRemaining:", p.stakeRemaining);
            if (p.step == IOllaCore.RebalanceStep.Done) break;
        }

        IOllaCore.RebalanceProgress memory progressFinal = core.rebalanceProgress();
        console.log("\n=== FINAL CHECK ===");
        console.log("Step:", uint256(progressFinal.step), "- Expected: 5 (Done)");
        console.log("stakeRemaining:", progressFinal.stakeRemaining, "- Expected: 0");

        // If bug exists: step will still be 4 (StakeSurplus) and stakeRemaining > 0
        // If fixed: step should be 5 (Done) and stakeRemaining = 0
        assertEq(
            uint256(progressFinal.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "Rebalance should complete when stake() returns 0"
        );
        assertEq(progressFinal.stakeRemaining, 0, "stakeRemaining should be 0");
    }

    /// @notice Original test case with 1 ETH target buffer for comparison
    function test_Rebalance_WithTargetBuffer_OneEther() external {
        uint256 targetBuffer = 1 * DECIMALS;
        vm.prank(governance);
        core.setTargetBufferedAssets(targetBuffer);

        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // First stake: 8 ETH (leaving 1 ETH to stake + 1 ETH buffer = 2 ETH in contract)
        stakingManager.setStakeReturnAmount(8 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress1 = core.rebalanceProgress();
        assertEq(uint256(progress1.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "After first rebalance");
        assertEq(progress1.stakeRemaining, 1 * DECIMALS, "1 ETH remaining");

        // Set stake to return 0
        stakingManager.setStakeReturnAmount(0);

        // Second rebalance
        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress2 = core.rebalanceProgress();
        // With target buffer, it should complete correctly
        assertEq(uint256(progress2.step), uint256(IOllaCore.RebalanceStep.Done), "Should complete");
        assertEq(progress2.stakeRemaining, 0, "stakeRemaining should be 0");
    }

    /// @notice Verifies that when stake() returns 0 for the remainder, rebalance should complete.
    function test_Rebalance_ShouldComplete_WhenStakeReturnsZero() external {
        // Setup similar scenario but verify expected behavior
        uint256 targetBuffer = 1 * DECIMALS;
        vm.prank(governance);
        core.setTargetBufferedAssets(targetBuffer);

        uint256 depositAmount = 5 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // First stake: 3 ETH
        stakingManager.setStakeReturnAmount(3 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        vm.prank(operator);
        core.rebalance();

        // Second stake: 0 (no capacity)
        stakingManager.setStakeReturnAmount(0);

        vm.prank(operator);
        core.rebalance();

        // At this point, rebalance should detect that stake() returned 0
        // and advance to Done since no more progress can be made
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();

        // Verify that rebalance completes correctly when stake() returns 0
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "should complete when stake returns 0");
        assertEq(progress.stakeRemaining, 0, "stakeRemaining should be 0");
    }
}
