// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaCoreWithdrawalQueueTest is Test {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event WithdrawalClaimed(uint256 requestId, address recipient, uint256 assets);

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    WithdrawalQueue internal queue;
    address internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    SafetyModule internal safetyModule;
    address internal admin;
    address internal guardian;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        safetyModule =
            new SafetyModule(admin, guardian, address(core), address(vault), 1_000_000 ether, 500, 6_000, 1 days);
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(0);

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        queue = WithdrawalQueue(address(queueProxy));

        queue.initialize(address(vault), governance, 180_000);

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(queue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                        REQUEST REDEEM FLOW
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_BurnsShares() external {
        uint256 shares = _deposit(alice, 10 ether);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(4 ether, alice, alice);

        assertEq(requestId, 1, "request id starts at 1");
        assertEq(stAztec.balanceOf(alice), shares - 4 ether, "shares burned on request");
    }

    function test_RequestRedeem_LocksAssetsExpectedAtRequestRate() external {
        _deposit(alice, 12 ether);
        uint256 rate = core.exchangeRate();
        uint256 shares = 5 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(request.assetsExpected, expectedAssets, "assetsExpected locked at request rate");
        assertEq(request.rate, rate, "rate locked at request time");

        // Simulate rewards accrual by funding the accumulator; exchange rate reads its balance live.
        deal(address(asset), address(rewardsAccumulator), 3 ether);
        uint256 updatedRate = core.exchangeRate();
        assertGt(updatedRate, rate, "exchange rate should increase after rewards");
        request = queue.getRequest(requestId);
        assertEq(request.assetsExpected, expectedAssets, "assetsExpected unchanged after rate update");
        assertEq(request.rate, rate, "rate remains locked after update");
    }

    function test_RequestRedeem_EventMatchesQueueStorage() external {
        _deposit(alice, 20 ether);
        uint256 rate = core.exchangeRate();
        uint256 shares = 7 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemRequest(bob, alice, 1, alice, expectedAssets);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(request.recipient, bob, "queue stores recipient");
        assertEq(request.shares, shares, "queue stores share amount");
        assertEq(request.assetsExpected, expectedAssets, "queue stores assets expected");
        assertEq(request.rate, rate, "queue stores request rate");
    }

    function test_RequestRedeem_UpdatesQueueTotals() external {
        _deposit(alice, 25 ether);
        _deposit(bob, 15 ether);

        (, uint256 assetsExpectedAlice) = _requestRedeem(alice, 8 ether, alice);
        assertEq(queue.totalPendingAssets(), assetsExpectedAlice, "pending assets tracks first request");
        assertEq(queue.nextRequestId(), 2, "next request id increments after first request");
        assertEq(queue.nextPendingId(), 1, "next pending id stays at first request");

        (, uint256 assetsExpectedBob) = _requestRedeem(bob, 5 ether, bob);
        assertEq(
            queue.totalPendingAssets(), assetsExpectedAlice + assetsExpectedBob, "pending assets accumulates requests"
        );
        assertEq(queue.nextRequestId(), 3, "next request id increments after second request");
        assertEq(queue.nextPendingId(), 1, "next pending id remains earliest request");
    }

    function test_RequestRedeem_AssetsExpectedMatchesRate() external {
        _deposit(alice, 18 ether);
        // Fund the accumulator so the rate reflects reward backing.
        deal(address(asset), address(rewardsAccumulator), 6 ether);

        uint256 shares = 9 ether;
        uint256 expectedRate = core.withdrawalRate();
        // Hand-formula spec: shares * rate / 1e18. Tolerance absorbs the rounding wedge between
        // this two-step floor and the one-step mulDiv in convertToAssetsGross.
        uint256 expectedAssets = shares * expectedRate / 1e18;

        (uint256 requestId,) = _requestRedeem(alice, shares, alice);
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);

        assertApproxEqAbs(request.assetsExpected, expectedAssets, 10, "assetsExpected matches shares * rate / 1e18");
        assertEq(request.rate, expectedRate, "request rate matches core.withdrawalRate");
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_AllowsMultipleRequests() external {
        _deposit(alice, 15 ether);

        vm.prank(alice);
        uint256 firstRequestId = vault.requestRedeem(5 ether, alice, alice);
        vm.prank(alice);
        uint256 secondRequestId = vault.requestRedeem(2 ether, bob, alice);

        assertEq(firstRequestId, 1, "first request id");
        assertEq(secondRequestId, 2, "second request id");
        assertEq(queue.nextRequestId(), 3, "next request id increments");
    }

    function test_RevertWhen_RequestRedeemWhilePaused() external {
        _deposit(alice, 10 ether);

        vm.prank(governance);
        vault.pause();

        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vm.prank(alice);
        vault.requestRedeem(4 ether, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                                CLAIM FLOW
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ClaimNotFinalized() external {
        _deposit(alice, 10 ether);

        (uint256 requestId,) = _requestRedeem(alice, 5 ether, alice);

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__NotFinalized.selector, requestId));
        vm.prank(alice);
        vault.claimRequestById(requestId);
    }

    function test_RevertWhen_DoubleClaim() external {
        _deposit(alice, 10 ether);

        (uint256 requestId,) = _requestRedeem(alice, 5 ether, alice);
        core.rebalance();

        vm.prank(alice);
        vault.claimRequestById(requestId);

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__RequestNotFound.selector, requestId));
        vm.prank(alice);
        vault.claimRequestById(requestId);
    }

    function test_ClaimTransfersExpectedAssets() external {
        _deposit(alice, 12 ether);

        (uint256 requestId, uint256 assetsExpected) = _requestRedeem(alice, 6 ether, bob);
        core.rebalance();

        uint256 receiverBalanceBefore = asset.balanceOf(bob);

        vm.prank(bob);
        uint256 claimed = vault.claimRequestById(requestId);

        uint256 receiverBalanceAfter = asset.balanceOf(bob);
        assertEq(claimed, assetsExpected, "claimed assets should equal assetsExpected");
        assertEq(receiverBalanceAfter - receiverBalanceBefore, assetsExpected, "receiver gets expected assets");
    }

    function test_ClaimRequestById_ByControllerClaimsFullRequest() external {
        _deposit(alice, 14 ether);

        (uint256 requestId, uint256 assetsExpected) = _requestRedeem(alice, 7 ether, bob);
        core.rebalance();

        uint256 receiverBalanceBefore = asset.balanceOf(bob);

        vm.prank(bob);
        uint256 claimed = vault.claimRequestById(requestId);

        uint256 receiverBalanceAfter = asset.balanceOf(bob);
        assertEq(requestId, 1, "request id should be first");
        assertEq(claimed, assetsExpected, "redeem should claim full assetsExpected");
        assertEq(receiverBalanceAfter - receiverBalanceBefore, assetsExpected, "redeem claims full assetsExpected");
    }

    function test_RevertWhen_ClaimWhilePaused() external {
        _deposit(alice, 10 ether);

        (uint256 requestId,) = _requestRedeem(alice, 5 ether, alice);
        core.rebalance();

        vm.prank(governance);
        vault.pause();

        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vm.prank(alice);
        vault.claimRequestById(requestId);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    function _requestRedeem(address owner, uint256 shares, address recipient)
        internal
        returns (uint256 requestId, uint256 assetsExpected)
    {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, recipient, owner);
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assetsExpected = request.assetsExpected;
        return (requestId, assetsExpected);
    }
}

/// @title RealisticStakingManager
/// @notice Staking manager mock that actually transfers tokens to simulate real staking behavior.
/// @dev Used to test the finalized withdrawal claim bug where tokens get re-staked.
contract RealisticStakingManager is IStakingManager {
    using SafeERC20 for IERC20;
    IERC20 public stakingAsset;
    uint256 public totalStakedAmount;
    uint256 public pendingUnstakeAmount;
    bool public _hasFinalizedUnstakes;

    function initialize(IERC20 stakingAsset_, address, address, address, address, address) external override {
        stakingAsset = stakingAsset_;
    }

    function setGasThreshold(uint256) external override { }

    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        // Actually transfer tokens from caller (OllaCore) to this contract
        stakingAsset.safeTransferFrom(msg.sender, address(this), amount);
        totalStakedAmount += amount;
        return amount;
    }

    function unstake(uint256 amount) external override returns (uint256 unstakedAmount) {
        // Move from staked to pending unstake
        if (amount > totalStakedAmount) {
            amount = totalStakedAmount;
        }
        totalStakedAmount -= amount;
        pendingUnstakeAmount += amount;
        return amount;
    }

    function refreshAttesterState(address[] calldata) external override { }

    function purgeFailedQueueEntry(address) external override { }

    function getUnstakedFunds() external override returns (uint256 received, uint256 exitAmount) {
        // Transfer pending unstaked funds back to caller (OllaCore)
        received = pendingUnstakeAmount;
        if (received > 0) {
            pendingUnstakeAmount = 0;
            _hasFinalizedUnstakes = false;
            stakingAsset.safeTransfer(msg.sender, received);
        }
        return (received, 0);
    }

    function totalStaked() external view override returns (uint256) {
        return totalStakedAmount;
    }

    function pendingUnstakes() external view override returns (uint256) {
        return pendingUnstakeAmount;
    }

    function hasFinalizedUnstakes() external view override returns (bool) {
        return _hasFinalizedUnstakes;
    }

    function getStakingState() external view override returns (StakingState memory) {
        return
            StakingState({
                slashingDelta: 0, stakedAmount: totalStakedAmount, pendingUnstakeAmount: pendingUnstakeAmount
            });
    }

    function getSlashingDelta() external pure override returns (uint256) {
        return 0;
    }

    function getClaimableRewards() external pure override returns (uint256) {
        return 0;
    }

    function harvestRewards() external pure override returns (uint256) {
        return 0;
    }

    function getActivatedAttesterCount() external pure override returns (uint256) {
        return 0;
    }

    function getPendingUnstakeCount() external pure override returns (uint256) {
        return 0;
    }

    function isUnstakePending(address) external pure override returns (bool) {
        return false;
    }

    function core() external pure override returns (address) {
        return address(0);
    }

    function canStake(uint256) external pure override returns (bool) {
        return true;
    }

    function stakingProviderRegistry() external pure override returns (IStakingProviderRegistry) {
        return IStakingProviderRegistry(address(0));
    }

    function getProviderConfig() external pure override returns (ProviderConfig memory) {
        return ProviderConfig({ rewardsRecipient: address(0) });
    }

    function transitionRollup() external pure override returns (uint256 harvested) {
        return 0;
    }

    function rewardsRollup() external pure override returns (address) {
        return address(0);
    }
}

/// @title OllaCoreFinalizedWithdrawalBugTest
/// @notice Tests the bug where finalized-but-unclaimed withdrawals get re-staked on subsequent rebalances.
contract OllaCoreFinalizedWithdrawalBugTest is Test {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    RealisticStakingManager internal stakingManager;
    WithdrawalQueue internal queue;
    address internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    SafetyModule internal safetyModule;
    address internal admin;
    address internal guardian;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new RealisticStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        safetyModule =
            new SafetyModule(admin, guardian, address(core), address(vault), 1_000_000 ether, 500, 6_000, 1 days);
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(0);

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        queue = WithdrawalQueue(address(queueProxy));

        queue.initialize(address(vault), governance, 180_000);

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(queue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        // Initialize staking manager with asset
        stakingManager.initialize(asset, address(0), address(0), address(core), address(0), address(0));

        alice = makeAddr("alice");

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                    FINALIZED WITHDRAWAL CLAIM BUG
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests that finalized-but-unclaimed withdrawals can be claimed after a rebalance.
    /// @dev This test reproduces a bug where finalized withdrawal funds get re-staked on subsequent
    ///      rebalances, making them unclaimable due to insufficient balance.
    ///
    ///      The bug flow:
    ///      1. User deposits and funds get staked
    ///      2. User requests withdrawal
    ///      3. Rebalance #1: initiates unstake from staking manager
    ///      4. Rebalance #2: pulls unstaked funds back, finalizes withdrawal
    ///         - _finalizeWithdrawals() calls _decreaseBuffered() to reduce accounting
    ///         - But actual tokens remain in the core contract for user to claim
    ///      5. Rebalance #3: _syncBufferedWithBalance() sees actual balance > buffered
    ///         - Reconciles by INCREASING buffered to match actual balance
    ///         - _stakeSurplus() then stakes these tokens that should be reserved for claims
    ///      6. User tries to claim -> ERC20InsufficientBalance error
    function test_FinalizedWithdrawal_CanBeClaimedAfterRebalance() external {
        uint256 depositAmount = 100 ether;

        // Step 1: User deposits
        asset.mint(alice, depositAmount);
        vm.prank(alice);
        asset.approve(address(vault), depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount, alice, 0);

        // Verify initial state: funds are buffered in vault
        assertEq(asset.balanceOf(address(vault)), depositAmount, "funds should be in vault");

        // Step 2: First rebalance stakes the funds (no target buffer means all gets staked)
        core.rebalance();

        // Verify funds moved to staking manager
        assertEq(asset.balanceOf(address(vault)), 0, "vault should have 0 after staking");
        assertEq(asset.balanceOf(address(stakingManager)), depositAmount, "staking manager should have funds");

        // Step 3: User requests full withdrawal
        uint256 shares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        uint256 expectedAssets = request.assetsExpected;
        assertEq(expectedAssets, depositAmount, "expected assets should match deposit");

        // Step 4: Rebalance to initiate unstake (pending withdrawals > buffered)
        vm.warp(block.timestamp + 1 hours + 1);
        core.rebalance();

        // Funds should now be pending unstake in staking manager
        assertEq(stakingManager.pendingUnstakes(), depositAmount, "funds should be pending unstake");

        // Step 5: Rebalance to pull unstaked funds and finalize withdrawal
        {
            IOllaCore.LatestReport memory rpt = core.latestReport();
            vm.warp(rpt.timestamp + 1 hours + 1);
        }
        core.rebalance();

        // Verify withdrawal is finalized
        request = queue.getRequest(requestId);
        assertTrue(request.finalized, "withdrawal should be finalized");
        assertFalse(request.claimed, "withdrawal should not be claimed yet");

        // Funds should be back in vault, reserved for the claim
        uint256 vaultBalanceAfterFinalize = asset.balanceOf(address(vault));
        assertEq(vaultBalanceAfterFinalize, depositAmount, "vault should have funds for claim");

        // Step 6: Another rebalance - regression check for finalized funds.
        // Finalized-but-unclaimed funds should remain reserved in the vault.
        {
            IOllaCore.LatestReport memory rpt = core.latestReport();
            vm.warp(rpt.timestamp + 1 hours + 1);
        }
        core.rebalance();

        // Check if funds were incorrectly re-staked
        uint256 vaultBalanceAfterExtraRebalance = asset.balanceOf(address(vault));

        // Assertion should pass post-fix: funds remain reserved for claim.
        assertGe(
            vaultBalanceAfterExtraRebalance,
            expectedAssets,
            "vault should still have funds reserved for finalized withdrawal"
        );

        // Step 7: User claims finalized withdrawal.
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        assertEq(claimed, expectedAssets, "user should receive full expected assets");
        assertEq(asset.balanceOf(alice), expectedAssets, "alice should have her assets back");
    }

    function test_Rebalance_DoesNotReduceBalanceBelowFinalizedAssets() external {
        uint256 depositAmount = 100 ether;

        asset.mint(alice, depositAmount);
        vm.prank(alice);
        asset.approve(address(vault), depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount, alice, 0);

        core.rebalance();

        uint256 shares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        uint256 expectedAssets = request.assetsExpected;

        vm.warp(block.timestamp + 1 hours + 1);
        core.rebalance();
        {
            IOllaCore.LatestReport memory rpt = core.latestReport();
            vm.warp(rpt.timestamp + 1 hours + 1);
        }
        core.rebalance();

        request = queue.getRequest(requestId);
        assertTrue(request.finalized, "withdrawal should be finalized");
        assertFalse(request.claimed, "withdrawal should not be claimed");

        uint256 vaultBalanceBeforeRebalance = asset.balanceOf(address(vault));
        assertEq(vaultBalanceBeforeRebalance, expectedAssets, "vault should hold finalized assets");

        {
            IOllaCore.LatestReport memory rpt = core.latestReport();
            vm.warp(rpt.timestamp + 1 hours + 1);
        }
        core.rebalance();

        uint256 vaultBalanceAfterRebalance = asset.balanceOf(address(vault));
        assertGe(vaultBalanceAfterRebalance, expectedAssets, "rebalance should not reduce below finalized assets");
    }
}
