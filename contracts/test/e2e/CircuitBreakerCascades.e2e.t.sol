// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

/// @title CircuitBreakerCascadesE2ETest
/// @notice Phase 3 E2E: validates SafetyModule circuit breaker cascades and recovery.
///         Wires real OllaCore, OllaVault, WithdrawalQueue, SafetyModule
///         with MockAccountingStakingManager and MockRewardsAccumulator.
contract CircuitBreakerCascadesE2ETest is Test {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event CircuitBreakerTriggered(ISafetyModule.BreakerReason reason);
    event Paused();
    event Unpaused();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MIN_DELAY = 1 days;
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant PROTOCOL_FEE_BP = 500;
    uint256 internal constant TREASURY_FEE_SPLIT_BP = 5_000;

    /*//////////////////////////////////////////////////////////////
                             TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    OllaGovernance internal gov;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    WithdrawalQueue internal withdrawalQueue;
    SafetyModule internal safetyModule;
    MockAccountingStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockAztec internal asset;

    address internal admin;
    address internal guardian;
    address internal operator;
    address internal alice;
    address internal bob;
    address internal treasury;
    address internal providerRewards;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        treasury = makeAddr("treasury");
        providerRewards = makeAddr("providerRewards");

        asset = new MockAztec(address(this));

        // ---- Deploy OllaGovernance (impl + proxy + init) ----
        OllaGovernance govImpl = new OllaGovernance();
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(OllaGovernance.initialize, (MIN_DELAY, proposers, executors, admin, treasury))
        );
        gov = OllaGovernance(payable(address(govProxy)));

        // ---- Deploy OllaCore (impl + proxy) ----
        OllaCore coreImpl = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), "");
        core = OllaCore(address(coreProxy));

        // ---- Deploy OllaVault (impl + proxy) ----
        OllaVault vaultImpl = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        vault = OllaVault(address(vaultProxy));

        // ---- Deploy satellite contracts ----
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new SafetyModule(
            admin,
            guardian,
            address(core),
            address(vault),
            1_000_000 * DECIMALS, // depositCap
            500, // minRateDropBps (5%)
            5_000, // maxQueueRatioBps (50%)
            7 days // maxAccountingDelay — generous default; individual tests override
        );
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(0);

        // ---- Deploy WithdrawalQueue (proxy) ----
        WithdrawalQueue queueImpl = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImpl), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        withdrawalQueue.initialize(address(vault), address(gov), 180_000);

        // ---- Configure mock staking manager ----
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));
        stakingManager.setUnstakedToken(asset);
        stakingManager.setProviderRewardsRecipient(providerRewards);

        // ---- Initialize OllaCore ----
        core.initialize(
            asset,
            stAztec,
            stakingManager,
            PROTOCOL_FEE_BP,
            TREASURY_FEE_SPLIT_BP,
            address(gov),
            rewardsAccumulator,
            address(safetyModule)
        );

        // ---- Initialize OllaVault ----
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), address(gov));

        // ---- Wire contracts ----
        vm.prank(address(gov));
        core.setVault(address(vault));
        vm.prank(admin);
        gov.setCore(address(core));

        // ---- Unpause ----
        vm.prank(address(gov));
        core.unpause();
        vm.prank(address(gov));
        vault.unpause();

        // ---- Advance past rebalance cooldown ----
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address depositor, uint256 amount) internal returns (uint256 shares) {
        asset.mint(depositor, amount);
        vm.prank(depositor);
        asset.approve(address(vault), amount);
        vm.prank(depositor);
        shares = vault.deposit(amount, depositor, 0);
    }

    function _fullRebalance() internal returns (uint256, uint256, uint256, uint256) {
        vm.prank(operator);
        return core.rebalance();
    }

    function _warpPastCooldown() internal {
        vm.warp(block.timestamp + 1 hours + 1);
    }

    function _assertDepositBlocked(address depositor, uint256 amount) internal {
        asset.mint(depositor, amount);
        vm.prank(depositor);
        asset.approve(address(vault), amount);
        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__SafetyModulePaused.selector));
        vm.prank(depositor);
        vault.deposit(amount, depositor, 0);
    }

    function _assertInstantRedeemBlocked(address redeemer, uint256 shares) internal {
        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__SafetyModulePaused.selector));
        vm.prank(redeemer);
        vault.instantRedeem(shares, redeemer, 0);
    }

    /*//////////////////////////////////////////////////////////////
        TEST 3A: RATE DROP DURING REBALANCE PAUSES PROTOCOL
    //////////////////////////////////////////////////////////////*/

    function test_RateDropDuringRebalance_PausesProtocol() external {
        // --- Setup: alice deposits 100e18, stake 90e18, buffer 10e18 ---
        _performDeposit(alice, 100 * DECIMALS);

        stakingManager.setStakeReturnAmount(90 * DECIMALS);
        stakingManager.setTotalStaked(90 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _fullRebalance();

        assertEq(vault.bufferedAssets(), 10 * DECIMALS, "pre: buffer should be 10e18");
        assertFalse(safetyModule.isPaused(), "pre: should not be paused");

        // --- Set tight rate drop threshold (5%) via admin ---
        vm.prank(admin);
        safetyModule.setMinRateDropBps(500);

        // --- Simulate slashing: 10e18 out of 90e18 staked (>5% drop) ---
        stakingManager.setSlashingDelta(10 * DECIMALS);
        stakingManager.setTotalStaked(90 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.clearStakeReturnAmount();

        _warpPastCooldown();

        // --- Rebalance triggers rate drop breaker ---
        vm.expectEmit(true, true, true, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.RateDrop);
        _fullRebalance();

        // --- Verify paused ---
        assertTrue(safetyModule.isPaused(), "should be paused after rate drop");

        // --- Verify deposit blocked ---
        _assertDepositBlocked(bob, 10 * DECIMALS);

        // --- Verify instant redeem blocked ---
        _assertInstantRedeemBlocked(alice, 1 * DECIMALS);

        // --- Recovery: guardian unpause ---
        vm.expectEmit(true, true, true, true, address(safetyModule));
        emit Unpaused();
        vm.prank(guardian);
        safetyModule.unpause();

        assertFalse(safetyModule.isPaused(), "should be unpaused after guardian action");

        // --- Verify all operations succeed after unpause ---
        uint256 bobShares = _performDeposit(bob, 10 * DECIMALS);
        assertGt(bobShares, 0, "recovery: bob deposit should mint shares");

        // Instant redeem works
        uint256 bobAssetsBefore = asset.balanceOf(bob);
        vm.prank(bob);
        vault.instantRedeem(bobShares / 2, bob, 0);
        assertGt(asset.balanceOf(bob), bobAssetsBefore, "recovery: bob instant redeem should return assets");

        // Request redeem works
        vm.prank(bob);
        vault.requestRedeem(bobShares / 4, bob, bob);

        // Next rebalance completes normally
        _warpPastCooldown();
        _fullRebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "recovery: rebalance should complete");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 3B: QUEUE RATIO BREAKER DURING REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_QueueRatioBreaker_DuringRebalance() external {
        // --- Setup: alice deposits 100e18, stake 90e18, buffer 10e18 ---
        _performDeposit(alice, 100 * DECIMALS);

        stakingManager.setStakeReturnAmount(90 * DECIMALS);
        stakingManager.setTotalStaked(90 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _fullRebalance();

        // --- Set queue ratio threshold to 40% via admin ---
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(4_000);

        // --- alice requests redeem of 50e18 shares (50% of total > 40% threshold) ---
        vm.prank(alice);
        vault.requestRedeem(50 * DECIMALS, alice, alice);

        _warpPastCooldown();

        // --- Rebalance triggers queue ratio breaker ---
        vm.expectEmit(true, true, true, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.QueueRatio);
        _fullRebalance();

        // --- Verify paused ---
        assertTrue(safetyModule.isPaused(), "should be paused after queue ratio breach");

        // --- Verify deposit blocked ---
        _assertDepositBlocked(bob, 10 * DECIMALS);

        // --- Recovery: guardian unpause ---
        vm.prank(guardian);
        safetyModule.unpause();
        assertFalse(safetyModule.isPaused(), "should be unpaused");

        // --- Verify all operations work after unpause ---
        uint256 bobShares = _performDeposit(bob, 10 * DECIMALS);
        assertGt(bobShares, 0, "recovery: bob deposit should mint shares");

        // Request redeem works (instant redeem is blocked while pending withdrawals exceed buffer)
        vm.prank(bob);
        vault.requestRedeem(bobShares / 2, bob, bob);

        // Next rebalance processes the queue and completes
        _warpPastCooldown();
        _fullRebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "recovery: rebalance should complete");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 3C: ACCOUNTING LIVENESS TRIGGERS WHEN STALE
    //////////////////////////////////////////////////////////////*/

    function test_AccountingLiveness_TriggersWhenStale() external {
        // --- Setup: alice deposits 100e18, stake 90e18, complete first rebalance ---
        _performDeposit(alice, 100 * DECIMALS);

        stakingManager.setStakeReturnAmount(90 * DECIMALS);
        stakingManager.setTotalStaked(90 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _fullRebalance();

        assertFalse(safetyModule.isPaused(), "pre: should not be paused");

        // --- Tighten maxAccountingDelay to 1 day via admin ---
        vm.prank(admin);
        safetyModule.setMaxAccountingDelay(1 days);

        // --- Warp past maxAccountingDelay (1 day) without rebalancing ---
        vm.warp(block.timestamp + 2 days);

        // --- Rebalance triggers accounting liveness breaker ---
        vm.expectEmit(true, true, true, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.AccountingStale);
        _fullRebalance();

        // --- Verify paused ---
        assertTrue(safetyModule.isPaused(), "should be paused after stale accounting");

        // --- Verify deposit blocked ---
        _assertDepositBlocked(bob, 10 * DECIMALS);

        // --- Recovery: guardian unpause ---
        vm.prank(guardian);
        safetyModule.unpause();
        assertFalse(safetyModule.isPaused(), "should be unpaused");

        // --- Rebalance now updates accounting timestamp ---
        _warpPastCooldown();
        _fullRebalance();

        // --- Verify all operations succeed ---
        uint256 bobShares = _performDeposit(bob, 10 * DECIMALS);
        assertGt(bobShares, 0, "recovery: bob deposit should mint shares");

        // Instant redeem works
        vm.prank(bob);
        vault.instantRedeem(bobShares / 2, bob, 0);

        // Request redeem works
        vm.prank(bob);
        vault.requestRedeem(bobShares / 4, bob, bob);

        // --- Verify liveness doesn't re-trigger within delay ---
        _warpPastCooldown();
        _fullRebalance();
        assertFalse(safetyModule.isPaused(), "should not re-trigger within delay");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 3D: CASCADING BREAKERS — RATE DROP THEN QUEUE RATIO
    //////////////////////////////////////////////////////////////*/

    function test_CascadingBreakers_RateDropThenQueueRatio() external {
        // --- Setup: alice deposits 200e18, stake 190e18, buffer 10e18 ---
        _performDeposit(alice, 200 * DECIMALS);

        stakingManager.setStakeReturnAmount(190 * DECIMALS);
        stakingManager.setTotalStaked(190 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _fullRebalance();

        assertEq(vault.bufferedAssets(), 10 * DECIMALS, "pre: buffer should be 10e18");

        // --- Set thresholds: 3% rate drop, 40% queue ratio ---
        vm.prank(admin);
        safetyModule.setMinRateDropBps(300);
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(4_000);

        // --- alice requests redeem 100e18 shares (50% > 40% threshold) ---
        vm.prank(alice);
        vault.requestRedeem(100 * DECIMALS, alice, alice);

        // --- Simulate slashing: 10e18 (>3% of 190e18 staked) ---
        stakingManager.setSlashingDelta(10 * DECIMALS);
        stakingManager.setTotalStaked(190 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.clearStakeReturnAmount();

        _warpPastCooldown();

        // --- First breaker: queue ratio fires first (checked before rate drop) ---
        vm.expectEmit(true, true, true, true, address(safetyModule));
        emit CircuitBreakerTriggered(ISafetyModule.BreakerReason.QueueRatio);
        _fullRebalance();

        assertTrue(safetyModule.isPaused(), "should be paused after first breaker (queue ratio)");
        _assertDepositBlocked(bob, 10 * DECIMALS);

        // --- Guardian unpause after first breaker ---
        vm.prank(guardian);
        safetyModule.unpause();
        assertFalse(safetyModule.isPaused(), "should be unpaused after first recovery");

        // --- Second rebalance triggers breaker again ---
        // Keep slashingDelta at 10 (must be monotonically non-decreasing).

        _warpPastCooldown();
        _fullRebalance();

        assertTrue(safetyModule.isPaused(), "should be paused after second breaker");
        _assertDepositBlocked(bob, 10 * DECIMALS);

        // --- Final recovery: admin raises queue ratio threshold, guardian unpauses ---
        vm.prank(admin);
        safetyModule.setMaxQueueRatioBps(9_000);
        vm.prank(guardian);
        safetyModule.unpause();

        // --- Protocol fully functional: verify all operations ---
        uint256 bobShares = _performDeposit(bob, 50 * DECIMALS);
        assertGt(bobShares, 0, "final recovery: bob deposit should mint shares");

        // Full rebalance cycle completes with rewards (do before adding queue pressure)
        stakingManager.setHarvestedRewards(5 * DECIMALS);
        stakingManager.setClaimableRewards(1);
        _warpPastCooldown();
        _fullRebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(
            uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "final recovery: rebalance should complete"
        );
        assertFalse(safetyModule.isPaused(), "final recovery: should not be paused after normal rebalance");

        // Request redeem works (instant redeem is blocked while pending withdrawals exceed buffer)
        vm.prank(bob);
        vault.requestRedeem(bobShares / 4, bob, bob);
    }

    /*//////////////////////////////////////////////////////////////
        TEST 3E: BREAKER DURING REBALANCE DOES NOT CORRUPT STATE
    //////////////////////////////////////////////////////////////*/

    function test_BreakerDuringRebalance_DoesNotCorruptState() external {
        // --- Setup: alice deposits 100e18, stake 90e18, buffer 10e18 ---
        _performDeposit(alice, 100 * DECIMALS);

        stakingManager.setStakeReturnAmount(90 * DECIMALS);
        stakingManager.setTotalStaked(90 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _fullRebalance();

        uint256 totalAssetsBefore = core.totalAssets();
        uint256 totalSupplyBefore = stAztec.totalSupply();

        // --- Set aggressive 1% rate drop threshold ---
        vm.prank(admin);
        safetyModule.setMinRateDropBps(100);

        // --- Simulate small slashing: 2e18 (>1% of ~100e18 total) ---
        stakingManager.setSlashingDelta(2 * DECIMALS);
        stakingManager.setTotalStaked(90 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.clearStakeReturnAmount();

        _warpPastCooldown();

        // --- Rebalance completes but breaker fires ---
        _fullRebalance();

        assertTrue(safetyModule.isPaused(), "should be paused after breaker");

        // --- Verify accounting consistency ---
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete");

        // totalAssets should reflect slashing loss
        uint256 totalAssetsAfter = core.totalAssets();
        assertLt(totalAssetsAfter, totalAssetsBefore, "totalAssets should decrease from slashing");

        // totalSupply unchanged (no fee minting when rewards are negative)
        assertEq(stAztec.totalSupply(), totalSupplyBefore, "totalSupply should not change");

        // Exchange rate should reflect slashing
        IOllaCore.LatestReport memory report = core.latestReport();
        assertLt(report.exchangeRate, 1e18, "exchange rate should drop below 1e18");

        // --- Recovery: guardian unpause, next rebalance completes ---
        vm.prank(guardian);
        safetyModule.unpause();

        // slashingDelta is cumulative — keep it at 2e18 (cannot decrease)
        _warpPastCooldown();
        _fullRebalance();

        // Rebalance completes normally
        progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "recovery rebalance should complete");

        // --- Verify all operations work after recovery ---
        uint256 bobShares = _performDeposit(bob, 10 * DECIMALS);
        assertGt(bobShares, 0, "recovery: bob can deposit");

        // Exchange rate still reflects slashing but is stable
        IOllaCore.LatestReport memory report2 = core.latestReport();
        assertApproxEqAbs(report2.exchangeRate, report.exchangeRate, 1, "exchange rate should be stable after recovery");

        // Instant redeem works (while buffer is still available from bob's deposit)
        uint256 bobAssetsBefore = asset.balanceOf(bob);
        vm.prank(bob);
        vault.instantRedeem(bobShares / 4, bob, 0);
        assertGt(asset.balanceOf(bob), bobAssetsBefore, "recovery: instant redeem returns assets");

        // Request redeem works
        vm.prank(bob);
        vault.requestRedeem(bobShares / 4, bob, bob);

        // Widen rate drop threshold before recovery rebalance so the mock's stale
        // totalStaked doesn't re-trigger the aggressive 1% threshold
        vm.prank(admin);
        safetyModule.setMinRateDropBps(5_000);

        // Recovery rebalance completes normally
        _warpPastCooldown();
        _fullRebalance();

        assertFalse(safetyModule.isPaused(), "recovery: should not re-pause on normal rebalance");
        progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "recovery: rebalance should complete");
    }
}
