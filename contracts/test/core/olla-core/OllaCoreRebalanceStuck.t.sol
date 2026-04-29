// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, console } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
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
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        // Configure staking manager to mint rewards directly to rewards vault
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(core), governance);

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
    /// This matches the mock-loop scenario: 200k deposit.
    function test_Rebalance_StuckInStakeSurplus_WhenPartialStakeCapacity() external {
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

    /// @notice Liveness path: when a rebalance is resumed at StakeSurplus with non-zero
    ///         stakeRemaining and the staking manager subsequently returns 0 from stake(),
    ///         the cycle must converge to Done instead of deadlocking.
    function test_Rebalance_ShouldComplete_WhenStakeReturnsZero() external {
        uint256 depositAmount = 5 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // First stake call: mock returns 3 ETH (allowing return > requested so the mock
        // actually transfers 3 even though amount=5). Stakeable = 5 (no withdrawals,
        // no target). Result: stakedAmount = 3, stakeRemaining = 2, parks at StakeSurplus.
        stakingManager.setStakeReturnAmount(3 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressMid = core.rebalanceProgress();
        assertEq(
            uint256(progressMid.step),
            uint256(IOllaCore.RebalanceStep.StakeSurplus),
            "should park at StakeSurplus after partial stake"
        );
        assertGt(progressMid.stakeRemaining, 0, "stakeRemaining should be non-zero after partial stake");

        // Second stake call: mock returns 0 → canStake() returns false on resume →
        // `_runRebalance` zeroes stakeRemaining and advances step to Done.
        stakingManager.setStakeReturnAmount(0);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();

        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "should complete when stake returns 0");
        assertEq(progress.stakeRemaining, 0, "stakeRemaining should be 0");
    }
}
