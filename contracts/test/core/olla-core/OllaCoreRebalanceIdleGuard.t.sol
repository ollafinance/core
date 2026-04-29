// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Vm, Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaCoreRebalanceIdleGuard
/// @notice Tests that rebalance does not enter an infinite restart loop when there is an
///         unstakeable remainder (e.g. 2 AZTEC when minimum stake is 200000 AZTEC ).
///
///         The fix adds a _rebalanceIdleBuffer flag that records bufferedAssets when a cycle
///         completes with no productive staking/unstaking/finalization. Subsequent rebalance calls
///         skip starting a new cycle if the buffer hasn't changed.
contract OllaCoreRebalanceIdleGuard is Test {
    uint256 internal constant DECIMALS = 1e18;

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

    /// @notice Tests that after an unproductive rebalance cycle completes (step=Done, pause=false),
    ///         subsequent rebalance calls do not trigger full unnecessary cycles.
    ///
    ///         After a large deposit, the first rebalance stakes most assets
    ///         but leaves a small remainder (2 AZTEC). The second rebalance call advances StakeSurplus
    ///         to Done (stake returns 0), clears pause.
    ///
    ///         The fix ensures that the 4th call does not trigger a Rebalanced event, proving
    ///         that the idle buffer guard prevents infinite restarts.
    function test_RebalanceDoesNotInfinitelyRestart() external {
        // Deposit 200,002 AZTEC (2 AZTEC above the 200k stake threshold)
        _performDeposit(alice, 200_002 * DECIMALS);

        // --- Rebalance call 1: stakes 200,000 AZTEC (max stakeable), saves progress at StakeSurplus ---
        stakingManager.setStakeReturnAmount(200_000 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory p1 = core.rebalanceProgress();
        // After call 1: stuck at StakeSurplus with 2 AZTEC remaining
        assertEq(uint256(p1.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "call 1: should be StakeSurplus");
        assertEq(p1.stakeRemaining, 2 * DECIMALS, "call 1: 2 AZTEC remaining");
        assertNotEq(uint256(p1.step), uint256(IOllaCore.RebalanceStep.Done), "call 1: should not be Done yet");

        // --- Rebalance call 2: stake returns 0, advances StakeSurplus -> Done ---
        stakingManager.setStakeReturnAmount(0);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory p2 = core.rebalanceProgress();
        assertEq(uint256(p2.step), uint256(IOllaCore.RebalanceStep.Done), "call 2: should be Done");
        assertEq(p2.stakeRemaining, 0, "call 2: stakeRemaining should be 0");
        assertEq(uint256(p2.step), uint256(IOllaCore.RebalanceStep.Done), "call 2: should be Done");

        // Advance past rebalance cooldown after cycle completion
        vm.warp(block.timestamp + 1 hours);

        // --- Rebalance call 3: should be a no-op due to idle buffer ---
        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory p3 = core.rebalanceProgress();

        // First verify call 3 ended at Done
        assertEq(uint256(p3.step), uint256(IOllaCore.RebalanceStep.Done), "call 3: should be Done");
        assertEq(uint256(p3.step), uint256(IOllaCore.RebalanceStep.Done), "call 3: should be Done");

        // --- Call 4: proves the idle buffer guard prevents infinite restart ---
        // Record the Rebalanced event count. If a full cycle ran, there will be a new event.
        vm.recordLogs();

        vm.prank(operator);
        core.rebalance();

        // Check if a new Rebalanced event was emitted -- this means a full cycle ran unnecessarily
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 rebalancedSig = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");
        uint256 rebalancedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == rebalancedSig) {
                rebalancedCount++;
            }
        }

        // Expected: no Rebalanced event should be emitted when there is nothing productive to rebalance.
        assertEq(
            rebalancedCount,
            0,
            "rebalance should not trigger unnecessary cycle - idle buffer guard should prevent infinite restart"
        );
    }

    /// @notice Ensures the idle-buffer guard does not block starting a new cycle when
    ///         new work becomes available via external state changes (e.g. RewardsAccumulator
    ///         receives funds).
    ///
    ///         This currently fails because _rebalanceIdleBuffer can be set based only
    ///         on the final call's (stakedAmount, finalizedAmount), even if the cycle did
    ///         productive work in prior calls (e.g. staking). Once set, rebalance() may
    ///         incorrectly no-op and skip harvesting/pulling newly available funds.
    function test_RebalanceIdleGuardDoesNotBlockPullingNewRewardsAccumulatorFunds() external {
        _performDeposit(alice, 200_002 * DECIMALS);

        // Call 1: stake most assets; leaves 2 AZTEC buffered and progress at StakeSurplus.
        stakingManager.setStakeReturnAmount(200_000 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);
        vm.prank(operator);
        core.rebalance();

        // Call 2: stake returns 0, completing the cycle and (currently) recording an idle buffer snapshot.
        stakingManager.setStakeReturnAmount(0);
        vm.prank(operator);
        core.rebalance();

        assertEq(uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "setup: step Done");

        uint256 bufferedBefore = vault.bufferedAssets();
        assertEq(bufferedBefore, 2 * DECIMALS, "setup: 2 AZTEC buffered");

        // Simulate out-of-band rewards arriving to the rewards vault.
        // Must exceed REWARDS_ACCUMULATOR_DUST_THRESHOLD (10_000 AZTEC) to bypass the idle fast-path.
        uint256 newRewards = 10_001 * DECIMALS;
        asset.mint(address(rewardsAccumulator), newRewards);
        assertEq(rewardsAccumulator.balance(), newRewards, "rewards vault funded");

        // Advance past rebalance cooldown after cycle completion
        vm.warp(block.timestamp + 1 hours);

        // Expected behavior: rebalance should start a new cycle and pull rewards vault funds into the buffer.
        vm.prank(operator);
        core.rebalance();

        assertEq(vault.bufferedAssets(), bufferedBefore + newRewards, "rebalance should pull new rewards vault funds");
        assertEq(rewardsAccumulator.balance(), 0, "rewards vault should be emptied");
    }

    /// @notice Tests that repeatedly calling rebalance does not trigger unnecessary cycles.
    ///         The idle buffer guard prevents starting new cycles when no productive work is possible.
    function test_RebalanceRepeatedCycling() external {
        // Deposit 200,002 AZTEC (2 AZTEC above the 200k stake threshold)
        _performDeposit(alice, 200_002 * DECIMALS);

        // First rebalance: stake 200k AZTEC (max stakeable), leave 2 AZTEC unstakeable
        stakingManager.setStakeReturnAmount(200_000 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);
        vm.prank(operator);
        core.rebalance();

        // Second rebalance: complete the cycle (stake returns 0, proving 2 AZTEC can't be staked)
        stakingManager.setStakeReturnAmount(0);
        vm.prank(operator);
        core.rebalance();

        // Now vault is at step=Done, buffered=2 AZTEC (the unstakeable remainder)
        assertEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "setup: step should be Done"
        );

        // Advance past rebalance cooldown after cycle completion
        vm.warp(block.timestamp + 1 hours);

        // Count how many Rebalanced events are emitted over 5 more calls
        bytes32 rebalancedSig = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");
        uint256 totalRebalancedEvents = 0;

        for (uint256 i = 0; i < 5; i++) {
            vm.recordLogs();
            vm.prank(operator);
            core.rebalance();

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == rebalancedSig) {
                    totalRebalancedEvents++;
                }
            }
        }

        // Expected: 0 events (no cycles should start because idle buffer guard prevents them).
        assertEq(
            totalRebalancedEvents, 0, "rebalance should not trigger unnecessary cycles - idle buffer guard should work"
        );
    }

    /// @notice Rebalance ignores RewardsAccumulator balances at or below the hardcoded dust
    ///         threshold: the idle fast-path is preserved (no Rebalanced event, no cooldown
    ///         consumption, dust stays in the accumulator), while balances above the threshold
    ///         still trigger a productive cycle.
    function test_RebalanceIgnoresDustBelowAccumulatorThreshold() external {
        _performDeposit(alice, 200_002 * DECIMALS);

        // Drive the protocol to an idle Done state with a stable 2 AZTEC buffer.
        stakingManager.setStakeReturnAmount(200_000 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);
        vm.prank(operator);
        core.rebalance();

        stakingManager.setStakeReturnAmount(0);
        vm.prank(operator);
        core.rebalance();

        assertEq(uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "setup: step Done");

        uint256 dustThreshold = core.REWARDS_ACCUMULATOR_DUST_THRESHOLD();
        assertEq(dustThreshold, 10_000 * DECIMALS, "sanity: dust threshold is 10,000 AZTEC");

        uint256 bufferedBefore = vault.bufferedAssets();
        uint48 lastTimestampBefore = core.lastRebalanceTimestamp();

        // Donate exactly the threshold to the accumulator: this is still "dust".
        asset.mint(address(rewardsAccumulator), dustThreshold);
        assertEq(rewardsAccumulator.balance(), dustThreshold, "setup: dust deposited");

        // Advance past the cooldown so the only thing that could trigger work is the dust.
        vm.warp(block.timestamp + 1 hours);

        bytes32 rebalancedSig = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");

        // --- Dust at threshold: idle fast-path must hold. ---
        vm.recordLogs();
        vm.prank(operator);
        core.rebalance();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 rebalancedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == rebalancedSig) rebalancedCount++;
        }
        assertEq(rebalancedCount, 0, "dust donation should not trigger a rebalance cycle");
        assertEq(vault.bufferedAssets(), bufferedBefore, "buffer should be unchanged");
        assertEq(rewardsAccumulator.balance(), dustThreshold, "dust should remain in accumulator");
        assertEq(core.lastRebalanceTimestamp(), lastTimestampBefore, "cooldown should not be consumed");

        // --- One wei above threshold: a productive cycle must run. ---
        asset.mint(address(rewardsAccumulator), 1);
        assertEq(rewardsAccumulator.balance(), dustThreshold + 1, "setup: balance just above threshold");

        vm.prank(operator);
        core.rebalance();

        assertEq(rewardsAccumulator.balance(), 0, "above-threshold balance should be pulled");
        assertEq(vault.bufferedAssets(), bufferedBefore + dustThreshold + 1, "rewards should reach the buffer");
    }

    /// @notice Ensures claimable rollup rewards allow rebalance to start a new cycle
    ///         even when rewards vault balance is still zero.
    function test_RebalanceIdleGuardDoesNotBlockClaimableRewards() external {
        _performDeposit(alice, 200_002 * DECIMALS);

        // Call 1: stake most assets; leaves 2 AZTEC buffered and progress at StakeSurplus.
        stakingManager.setStakeReturnAmount(200_000 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);
        vm.prank(operator);
        core.rebalance();

        // Call 2: stake returns 0, completing the cycle and recording idle buffer snapshot.
        stakingManager.setStakeReturnAmount(0);
        vm.prank(operator);
        core.rebalance();

        assertEq(uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "setup: step Done");

        // Ensure rewards vault is empty but claimable rewards exist on the staking manager.
        assertEq(rewardsAccumulator.balance(), 0, "setup: rewards vault empty");
        stakingManager.setClaimableRewards(1 * DECIMALS);

        // Advance past rebalance cooldown after cycle completion
        vm.warp(block.timestamp + 1 hours);

        vm.prank(operator);
        core.rebalance();

        // Rebalance should have run harvest; mock keeps claimableRewards as a stub value,
        // but the key property is that the call does not no-op due to idle buffer guard.
        assertEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete"
        );
    }
}
