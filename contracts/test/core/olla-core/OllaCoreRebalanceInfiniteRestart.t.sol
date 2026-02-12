// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";

/// @title OllaCoreRebalanceInfiniteRestart
/// @notice Regression coverage for the infinite restart loop using the real WithdrawalQueue.
///
///         Root cause: after a rebalance cycle completes (step=Done) and clears the
///         pause flag, the next rebalance() call starts a brand new cycle. The new
///         cycle recalculates stakeRemaining = bufferedAssets - requiredBuffer, finds
///         the same small remainder, tries to stake it, gets 0 back, sets step=Done,
///         clears pause again — and the pattern repeats forever.
///
///         In the mock-loop each write.rebalance() call completes one cycle AND starts
///         a new one in the same tx, so the on-chain progress after each call always
///         reads as step=StakeSurplus (the new cycle's save point), causing the
///         off-chain loop to never see step=Done.
contract OllaCoreRebalanceInfiniteRestart is Test {
    uint256 internal constant DECIMALS = 1e18;

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

    /// @notice Ensures the fix works with the real WithdrawalQueue wiring.
    ///
    ///         After a large deposit with targetBuffer=0, the first rebalance stakes
    ///         most assets but leaves a small remainder (2 ETH). The second rebalance
    ///         call advances StakeSurplus to Done (stake returns 0), clears pause.
    ///
    ///         BUG: The third rebalance call should be a no-op (nothing to do), but
    ///         instead it starts a BRAND NEW rebalance cycle, re-pauses the vault,
    ///         recalculates stakeRemaining=2 ETH, fails to stake, sets Done, unpauses.
    ///         This repeats forever — each call triggers a full unnecessary cycle.
    ///
    ///         This test asserts that after 3 rebalance calls, calling rebalance a 4th
    ///         time should NOT cause the vault to be paused again. If the bug exists,
    ///         the 4th call will set _rebalancePaused=true (starting a new cycle).
    function test_RebalanceDoesNotInfinitelyRestart_WithWithdrawalQueue() external {
        // Target buffer = 0, so all buffered assets are "surplus" to stake
        vm.prank(governance);
        vault.setTargetBufferedAssets(0);

        // Deposit 200k ETH
        _performDeposit(alice, 200_000 * DECIMALS);

        // --- Rebalance call 1: stakes 199,998 ETH, saves progress at StakeSurplus ---
        stakingManager.setStakeReturnAmount(199_998 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory p1 = vault.rebalanceProgress();
        // After call 1: stuck at StakeSurplus with 2 ETH remaining
        assertEq(uint256(p1.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "call 1: should be StakeSurplus");
        assertEq(p1.stakeRemaining, 2 * DECIMALS, "call 1: 2 ETH remaining");
        assertTrue(vault.isRebalancePaused(), "call 1: pause should be active");

        // --- Rebalance call 2: stake returns 0, advances StakeSurplus -> Done ---
        stakingManager.setStakeReturnAmount(0);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory p2 = vault.rebalanceProgress();
        assertEq(uint256(p2.step), uint256(IOllaCore.RebalanceStep.Done), "call 2: should be Done");
        assertEq(p2.stakeRemaining, 0, "call 2: stakeRemaining should be 0");
        assertFalse(vault.isRebalancePaused(), "call 2: pause should be cleared");

        // --- Rebalance call 3: BUG DETECTION ---
        // If bug exists: this call sees step=Done, starts a new cycle, re-pauses,
        // goes through Harvest->PullUnstaked->FinalizeWithdrawals->InitiateUnstake->StakeSurplus,
        // recalculates stakeRemaining=2 ETH, stake returns 0, sets Done, clears pause.
        // Net effect: a full unnecessary rebalance cycle was run.
        //
        // Expected (correct behavior): rebalance should be a no-op or at least NOT
        // leave the vault in a state where calling it again would restart the cycle.
        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory p3 = vault.rebalanceProgress();

        // The bug manifests as: each rebalance call triggers a full new cycle.
        // If the step is Done and pause is false, the system is "stable".
        // But calling rebalance AGAIN will restart the cycle.
        // Let's prove it by checking if a 4th call causes a pause.

        // First verify call 3 ended at Done
        assertEq(uint256(p3.step), uint256(IOllaCore.RebalanceStep.Done), "call 3: should be Done");
        assertFalse(vault.isRebalancePaused(), "call 3: pause should be cleared");

        // --- Call 4: proves the infinite restart ---
        // Record the Rebalanced event count. If a full cycle ran, there will be a new event.
        vm.recordLogs();

        vm.prank(operator);
        vault.rebalance();

        // Check if a new Rebalanced event was emitted — this means a full cycle ran unnecessarily
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 rebalancedSig = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");
        uint256 rebalancedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == rebalancedSig) {
                rebalancedCount++;
            }
        }

        // BUG: A full rebalance cycle was triggered even though there was nothing productive to do.
        // The vault was paused and unpaused within a single call, running through all 6 steps
        // just to discover (again) that the 2 ETH remainder can't be staked.
        //
        // This test FAILS if the bug exists — a Rebalanced event should NOT be emitted
        // when there is nothing meaningful to rebalance.
        assertEq(
            rebalancedCount,
            0,
            "BUG: rebalance triggered a full unnecessary cycle on call 4 - infinite restart loop confirmed"
        );
    }
}
