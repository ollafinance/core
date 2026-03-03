// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { OwnableUpgradeable } from "@oz-upgradeable/access/OwnableUpgradeable.sol";
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
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaCorePermissionlessRebalance.t.sol
/// @notice Tests for permissionless rebalance and cooldown mechanism on OllaCore.
contract OllaCorePermissionlessRebalance is Test {
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant DEFAULT_REBALANCE_GAS_THRESHOLD = 180_000;

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal bob;
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal operator;
    address internal guardian;

    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 bufferedAssets);
    event RebalanceCooldownUpdated(uint256 indexed oldCooldown, uint256 indexed newCooldown);
    event RebalanceReset();

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

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        operator = makeAddr("operator");
        guardian = makeAddr("guardian");
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation),
            abi.encodeCall(WithdrawalQueue.initialize, (address(vault), governance, DEFAULT_REBALANCE_GAS_THRESHOLD))
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
        bob = makeAddr("bob");

        bytes32 operatorRole = core.OPERATOR_ROLE();
        bytes32 guardianRole = core.GUARDIAN_ROLE();
        vm.startPrank(governance);
        core.grantRole(operatorRole, operator);
        core.grantRole(guardianRole, guardian);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
    }

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    PERMISSIONLESS REBALANCE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone (not just OPERATOR_ROLE holders) can start a new rebalance cycle
    /// after the cooldown has elapsed.
    function test_Rebalance_AnyoneCanStartNewCycle() external {
        // Set a target buffer so not all assets are staked (some remain in buffer)
        vm.prank(governance);
        core.setTargetBufferedAssets(2 * DECIMALS);

        _performDeposit(alice, 10 * DECIMALS);

        address randomCaller = makeAddr("randomCaller");

        // randomCaller has no roles
        assertFalse(core.hasRole(core.OPERATOR_ROLE(), randomCaller));
        assertFalse(core.hasRole(core.GUARDIAN_ROLE(), randomCaller));
        assertFalse(core.hasRole(core.DEFAULT_ADMIN_ROLE(), randomCaller));

        // Cooldown has already elapsed (setUp warped 1 hour)
        vm.prank(randomCaller);
        (,, uint256 stakedAmount, uint256 resultingBuffer) = core.rebalance();

        // Verify rebalance completed
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "Rebalance should complete");

        // The cycle ran: resultingBuffer should reflect target buffer
        assertEq(resultingBuffer, 2 * DECIMALS, "resultingBuffer should equal target buffer");
        // Some assets should have been staked
        assertEq(stakedAmount, 8 * DECIMALS, "stakedAmount should be deposit minus target buffer");
    }

    /// @notice Rebalance reverts when the cooldown period has not elapsed since last report.
    function test_RevertWhen_Rebalance_CooldownNotElapsed() external {
        _performDeposit(alice, 10 * DECIMALS);

        // Complete a rebalance cycle to set the latest report timestamp
        core.rebalance();

        // Immediately try another rebalance without warping
        vm.expectRevert(
            abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceCooldownActive.selector, uint256(0), uint256(1 hours))
        );
        core.rebalance();
    }

    /// @notice An in-progress rebalance cycle can be continued by any address without cooldown.
    function test_Rebalance_AnyoneCanContinueInProgressCycle() external {
        // Setup: target buffer = 0 so everything gets staked
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _performDeposit(alice, 10 * DECIMALS);

        // Configure staking manager to only stake a partial amount per call,
        // causing the rebalance to pause at StakeSurplus with stakeRemaining > 0.
        stakingManager.setStakeReturnAmount(3 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        // First caller starts the cycle
        address caller1 = makeAddr("caller1");
        vm.prank(caller1);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress1 = core.rebalanceProgress();
        assertEq(
            uint256(progress1.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Should be in StakeSurplus step"
        );
        assertGt(progress1.stakeRemaining, 0, "Should have stakeRemaining > 0");

        // Clear the fixed return amount so mock returns whatever is passed in
        stakingManager.clearStakeReturnAmount();

        // Second caller continues the in-progress cycle (no cooldown needed)
        address caller2 = makeAddr("caller2");
        vm.prank(caller2);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress2 = core.rebalanceProgress();
        assertEq(uint256(progress2.step), uint256(IOllaCore.RebalanceStep.Done), "Should have completed");
        assertEq(progress2.stakeRemaining, 0, "stakeRemaining should be 0");
    }

    /// @notice After a cycle completes, the cooldown must elapse before the next cycle can start.
    /// Warp past cooldown and verify next cycle succeeds.
    function test_Rebalance_CooldownResetsAfterCycleCompletion() external {
        _performDeposit(alice, 10 * DECIMALS);

        // Complete first cycle
        core.rebalance();
        IOllaCore.RebalanceProgress memory progress1 = core.rebalanceProgress();
        assertEq(uint256(progress1.step), uint256(IOllaCore.RebalanceStep.Done), "First cycle should complete");

        // Immediately trying should revert (cooldown active)
        vm.expectRevert(
            abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceCooldownActive.selector, uint256(0), uint256(1 hours))
        );
        core.rebalance();

        // Deposit more to ensure there is work to do in the next cycle
        _performDeposit(alice, 5 * DECIMALS);

        // Warp past cooldown (use +1 to ensure strictly past)
        vm.warp(block.timestamp + 1 hours + 1);

        // Now it should succeed
        core.rebalance();
        IOllaCore.RebalanceProgress memory progress2 = core.rebalanceProgress();
        assertEq(uint256(progress2.step), uint256(IOllaCore.RebalanceStep.Done), "Second cycle should complete");
    }

    /// @notice After completing a cycle, an immediate new cycle is blocked by cooldown.
    /// After warping, the new cycle succeeds.
    function test_Rebalance_RepeatedCyclesBlockedByCooldown() external {
        // Record timestamps for clarity
        uint256 ts0 = block.timestamp; // setUp warped to 1+3600 = 3601

        _performDeposit(alice, 10 * DECIMALS);

        // Complete cycle 1 at ts0
        core.rebalance();

        // Try immediate new cycle -- should revert (elapsed = 0)
        vm.expectRevert(
            abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceCooldownActive.selector, uint256(0), uint256(1 hours))
        );
        core.rebalance();

        // Deposit more to give the next cycle work
        _performDeposit(alice, 5 * DECIMALS);

        // Warp past cooldown and succeed (cycle 2)
        uint256 ts1 = ts0 + 1 hours + 1;
        vm.warp(ts1);
        core.rebalance();
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "Cycle after warp should complete");

        // Again, immediate retry reverts
        vm.expectRevert();
        core.rebalance();

        // Deposit + warp again (cycle 3)
        _performDeposit(alice, 5 * DECIMALS);
        uint256 ts2 = ts1 + 1 hours + 1;
        vm.warp(ts2);
        core.rebalance();
        IOllaCore.RebalanceProgress memory progress2 = core.rebalanceProgress();
        assertEq(uint256(progress2.step), uint256(IOllaCore.RebalanceStep.Done), "Third cycle should complete");
    }

    /*//////////////////////////////////////////////////////////////
                    COOLDOWN CONFIGURATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Governance can set the rebalance cooldown and the correct event is emitted.
    function test_SetRebalanceCooldown_UpdatesAndEmits() external {
        uint256 newCooldown = 30 minutes;

        vm.expectEmit(true, true, false, false);
        emit RebalanceCooldownUpdated(1 hours, newCooldown);

        vm.prank(governance);
        core.setRebalanceCooldown(newCooldown);

        assertEq(core.rebalanceCooldown(), newCooldown, "Cooldown should be updated");
    }

    /// @notice Non-admin addresses cannot call setRebalanceCooldown.
    function test_RevertWhen_SetRebalanceCooldown_NonAdmin() external {
        address randomCaller = makeAddr("randomCaller");

        vm.prank(randomCaller);
        vm.expectRevert();
        core.setRebalanceCooldown(30 minutes);
    }

    /// @notice Setting cooldown below MIN_REBALANCE_COOLDOWN (10 minutes) but > 0 reverts.
    function test_RevertWhen_SetRebalanceCooldown_BelowMinimum() external {
        uint256 tooLow = 9 minutes; // Below MIN_REBALANCE_COOLDOWN = 10 minutes

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidParameter.selector));
        core.setRebalanceCooldown(tooLow);
    }

    /// @notice Setting cooldown above MAX_REBALANCE_COOLDOWN (24 hours) reverts.
    function test_RevertWhen_SetRebalanceCooldown_AboveMaximum() external {
        uint256 tooHigh = 25 hours; // Above MAX_REBALANCE_COOLDOWN = 24 hours

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidParameter.selector));
        core.setRebalanceCooldown(tooHigh);
    }

    /// @notice Setting cooldown to 0 reverts with OllaCore__InvalidParameter.
    function test_RevertWhen_SetRebalanceCooldown_Zero() external {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidParameter.selector));
        core.setRebalanceCooldown(0);
    }

    /*//////////////////////////////////////////////////////////////
                  USER OPS DURING REBALANCE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit and redeem work even while a rebalance is in progress.
    function test_UserOps_DuringInProgressRebalance() external {
        // Setup: target buffer = 0, partial staking
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 aliceShares = _performDeposit(alice, 10 * DECIMALS);

        // Configure partial staking to leave rebalance in-progress
        stakingManager.setStakeReturnAmount(3 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Should be in StakeSurplus");

        // Deposit from bob should succeed during in-progress rebalance
        uint256 bobShares = _performDeposit(bob, 5 * DECIMALS);
        assertGt(bobShares, 0, "Bob should receive shares");

        // Redeem from alice should succeed (instant redemption from buffer)
        // Alice has shares and there should be assets in the buffer from the deposit
        uint256 redeemShares = aliceShares / 10; // redeem a small portion
        vm.prank(alice);
        uint256 assetsRedeemed = vault.instantRedeem(redeemShares, alice, 0);
        assertGt(assetsRedeemed, 0, "Alice should receive assets from instant redemption");
    }

    /*//////////////////////////////////////////////////////////////
                ADMIN OPS DURING REBALANCE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice setRebalanceCooldown reverts with OllaCore__RebalanceInProgress during an in-progress rebalance.
    function test_RevertWhen_AdminOps_DuringInProgressRebalance() external {
        // Setup: target buffer = 0, partial staking
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _performDeposit(alice, 10 * DECIMALS);

        stakingManager.setStakeReturnAmount(3 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Should be in StakeSurplus");

        // setRebalanceCooldown should revert because rebalance is in progress
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.setRebalanceCooldown(30 minutes);

        // setTargetBufferedAssets should also revert
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.setTargetBufferedAssets(1 * DECIMALS);
    }

    /*//////////////////////////////////////////////////////////////
                PERMISSIONLESS updateAccounting TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Any address can call updateAccounting() when rebalance step is Done.
    function test_UpdateAccounting_PermissionlessAccess() external {
        _performDeposit(alice, 10 * DECIMALS);

        // Complete a rebalance cycle first so accounting has data
        core.rebalance();

        // Warp forward so the accounting update produces a fresh timestamp
        vm.warp(block.timestamp + 1 hours);

        // Random address calls updateAccounting (no role required)
        address randomCaller = makeAddr("randomCaller");
        assertFalse(core.hasRole(core.OPERATOR_ROLE(), randomCaller));

        vm.prank(randomCaller);
        core.updateAccounting();

        // If we got here without reverting, the call succeeded
        IOllaCore.LatestReport memory report = core.latestReport();
        assertEq(report.timestamp, block.timestamp, "Report timestamp should be updated");
    }

    /// @notice updateAccounting() reverts with OllaCore__RebalanceInProgress during an in-progress rebalance.
    function test_RevertWhen_UpdateAccounting_DuringRebalance() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _performDeposit(alice, 10 * DECIMALS);

        // Configure partial staking to leave rebalance in-progress
        stakingManager.setStakeReturnAmount(3 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Should be in StakeSurplus");

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.updateAccounting();
    }

    /*//////////////////////////////////////////////////////////////
                    FORCE REBALANCE RESET TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Guardian can force reset the rebalance state machine. Non-guardian reverts.
    function test_ForceRebalanceReset_GuardianOnly() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _performDeposit(alice, 10 * DECIMALS);

        // Put rebalance in-progress
        stakingManager.setStakeReturnAmount(3 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Should be in StakeSurplus");

        // Non-guardian cannot force reset
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        vm.expectRevert();
        core.forceRebalanceReset();

        // Operator cannot force reset either
        vm.prank(operator);
        vm.expectRevert();
        core.forceRebalanceReset();

        // Guardian can force reset
        vm.expectEmit(false, false, false, true);
        emit RebalanceReset();

        vm.prank(guardian);
        core.forceRebalanceReset();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(uint256(progressAfter.step), uint256(IOllaCore.RebalanceStep.Done), "Should be reset to Done");
        assertEq(progressAfter.stakeRemaining, 0, "stakeRemaining should be 0");
        assertEq(progressAfter.unstakeRemaining, 0, "unstakeRemaining should be 0");
    }

    /*//////////////////////////////////////////////////////////////
                reconcileBufferedAssets ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice reconcileBufferedAssets() is gated by DEFAULT_ADMIN_ROLE. Governance (admin) can call it;
    ///         an operator-only address cannot.
    function test_ReconcileBufferedAssets_AccessControl() external {
        _performDeposit(alice, 10 * DECIMALS);

        // Complete a rebalance so the state is Done
        core.rebalance();

        // Send some asset directly to the vault to create a reconcilable delta
        asset.mint(address(vault), 1 * DECIMALS);

        // Governance (DEFAULT_ADMIN_ROLE holder) CAN call reconcileBufferedAssets
        vm.prank(governance);
        uint256 delta = vault.reconcileBufferedAssets();
        assertEq(delta, 1 * DECIMALS, "governance should reconcile the donated amount");

        // Operator-only address CANNOT call reconcileBufferedAssets
        bytes32 adminRole = core.DEFAULT_ADMIN_ROLE();
        assertFalse(core.hasRole(adminRole, operator), "operator should not have DEFAULT_ADMIN_ROLE");

        // Send more to create another delta
        asset.mint(address(vault), 1 * DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        vault.reconcileBufferedAssets();
    }

    /*//////////////////////////////////////////////////////////////
           _lastRebalanceTimestamp ISOLATION FROM updateAccounting
    //////////////////////////////////////////////////////////////*/

    /// @notice Calling updateAccounting() standalone does NOT reset the rebalance cooldown.
    ///         The cooldown is driven by `_lastRebalanceTimestamp` which only updates on
    ///         rebalance completion, not on standalone accounting updates.
    function test_UpdateAccounting_DoesNotResetCooldown() external {
        _performDeposit(alice, 10 * DECIMALS);

        // Step 1: Complete a rebalance cycle (sets _lastRebalanceTimestamp to block.timestamp)
        core.rebalance();
        uint256 rebalanceCompletionTime = block.timestamp;

        // Step 2: Warp forward 30 minutes (not past the 1-hour cooldown)
        vm.warp(rebalanceCompletionTime + 30 minutes);

        // Step 3: Call updateAccounting() (updates _latestReport.timestamp but NOT _lastRebalanceTimestamp)
        core.updateAccounting();

        // Verify the report timestamp was updated
        IOllaCore.LatestReport memory report = core.latestReport();
        assertEq(
            report.timestamp,
            rebalanceCompletionTime + 30 minutes,
            "report timestamp should reflect updateAccounting call"
        );

        // Step 4: Immediately try to start a new rebalance — should still revert because
        // _lastRebalanceTimestamp was NOT affected by the updateAccounting() call.
        // elapsed = 30 minutes since rebalance completion, cooldown = 1 hour
        _performDeposit(alice, 5 * DECIMALS); // deposit more so next cycle has work
        vm.expectRevert(
            abi.encodeWithSelector(
                IOllaCore.OllaCore__RebalanceCooldownActive.selector, uint256(30 minutes), uint256(1 hours)
            )
        );
        core.rebalance();

        // Step 5: Warp past the original cooldown from step 1 (30 more minutes + 1 second)
        vm.warp(rebalanceCompletionTime + 1 hours + 1);

        // Step 6: Rebalance now succeeds (cooldown measured from _lastRebalanceTimestamp, not _latestReport)
        core.rebalance();
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(
            uint256(progress.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should succeed after original cooldown elapses"
        );
    }

    /*//////////////////////////////////////////////////////////////
           forceRebalanceReset COOLDOWN ELIGIBILITY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice After forceRebalanceReset(), the next rebalance cycle still respects the
    ///         original _lastRebalanceTimestamp. Force reset does NOT update the cooldown
    ///         timestamp, so if the cooldown from the previous completion has already elapsed,
    ///         a new rebalance can start immediately after the reset.
    function test_ForceRebalanceReset_DoesNotUpdateCooldownTimestamp() external {
        // Step 1: Complete a rebalance cycle
        _performDeposit(alice, 10 * DECIMALS);
        core.rebalance();
        IOllaCore.RebalanceProgress memory progress1 = core.rebalanceProgress();
        assertEq(uint256(progress1.step), uint256(IOllaCore.RebalanceStep.Done), "first cycle should complete");

        // Step 2: Deposit more and warp past cooldown
        _performDeposit(alice, 10 * DECIMALS);
        vm.warp(block.timestamp + 1 hours + 1);

        // Step 3: Start a new cycle but leave it in-progress (partial staking)
        vm.prank(governance);
        core.setTargetBufferedAssets(0);
        stakingManager.setStakeReturnAmount(3 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        core.rebalance();
        IOllaCore.RebalanceProgress memory progress2 = core.rebalanceProgress();
        assertEq(
            uint256(progress2.step),
            uint256(IOllaCore.RebalanceStep.StakeSurplus),
            "should be in StakeSurplus (in-progress)"
        );

        // Step 4: Guardian calls forceRebalanceReset()
        vm.prank(guardian);
        core.forceRebalanceReset();

        IOllaCore.RebalanceProgress memory progressAfterReset = core.rebalanceProgress();
        assertEq(uint256(progressAfterReset.step), uint256(IOllaCore.RebalanceStep.Done), "should be reset to Done");

        // Step 5: Immediately try rebalance — it should succeed because the cooldown
        // was from the step-1 completion, and we already warped past it in step 2.
        // forceRebalanceReset does NOT set _lastRebalanceTimestamp.
        stakingManager.clearStakeReturnAmount();
        core.rebalance();
        IOllaCore.RebalanceProgress memory progress3 = core.rebalanceProgress();
        assertEq(
            uint256(progress3.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should succeed immediately after force reset since original cooldown already elapsed"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    CONCURRENT DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice If someone deposits between rebalance calls while stakeRemaining > 0,
    /// the current cycle completes with the original stakeRemaining. The concurrent deposit
    /// lands in the buffer and is available for the next cycle.
    function test_Rebalance_ConcurrentDeposit_StakeRemainingRecomputed() external {
        // Setup: target buffer = 0 so all assets should be staked
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        // Initial deposit of 10 ETH
        _performDeposit(alice, 10 * DECIMALS);

        // Configure staking to only stake 5 ETH per call, leaving stakeRemaining > 0
        stakingManager.setStakeReturnAmount(5 * DECIMALS);
        stakingManager.setAllowStakeReturnExceeds(true);

        // First rebalance: stakes 5 ETH, pauses at StakeSurplus with 5 remaining
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress1 = core.rebalanceProgress();
        assertEq(uint256(progress1.step), uint256(IOllaCore.RebalanceStep.StakeSurplus), "Should be in StakeSurplus");
        assertEq(progress1.stakeRemaining, 5 * DECIMALS, "Should have 5 ETH remaining to stake");

        // Concurrent deposit: bob deposits 10 more ETH while rebalance is in progress
        _performDeposit(bob, 10 * DECIMALS);

        // Verify buffer increased from the deposit
        assertEq(vault.bufferedAssets(), 15 * DECIMALS, "Buffer should have 5 remaining + 10 deposit");

        // Clear the fixed return amount so mock returns whatever is passed in
        stakingManager.clearStakeReturnAmount();

        // Second rebalance: continues with existing stakeRemaining = 5 ETH
        // The cycle finishes staking the original 5 and completes.
        (,, uint256 stakedAmount2, uint256 resultingBuffer) = core.rebalance();

        // The staked amount is the remaining 5 from the original calculation
        assertEq(stakedAmount2, 5 * DECIMALS, "Should stake the remaining 5 ETH");

        // The concurrent deposit of 10 ETH remains in the buffer
        assertEq(resultingBuffer, 10 * DECIMALS, "10 ETH from concurrent deposit should remain in buffer");

        IOllaCore.RebalanceProgress memory progress2 = core.rebalanceProgress();
        assertEq(uint256(progress2.step), uint256(IOllaCore.RebalanceStep.Done), "Should have completed");

        // The next cycle (after cooldown) can stake the remaining buffered assets
        _performDeposit(bob, 1 * DECIMALS); // small deposit to ensure work available
        vm.warp(block.timestamp + 1 hours + 1);
        (,, uint256 stakedAmount3,) = core.rebalance();
        assertGt(stakedAmount3, 0, "Next cycle should stake the buffered assets from concurrent deposit");
    }
}
