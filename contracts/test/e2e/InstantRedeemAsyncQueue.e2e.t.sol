// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

/// @title InstantRedeemAsyncQueueE2ETest
/// @notice Phase 4 E2E: validates instant redemption + async withdrawal queue buffer contention.
///         Wires real OllaCore, OllaVault, WithdrawalQueue, SafetyModule
///         with MockAccountingStakingManager and MockRewardsAccumulator.
contract InstantRedeemAsyncQueueE2ETest is Test {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event InstantRedemption(
        address indexed owner,
        address indexed recipient,
        uint256 shares,
        uint256 grossAssets,
        uint256 fee,
        uint256 netAssets,
        uint256 exchangeRate
    );

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MIN_DELAY = 1 days;
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant PROTOCOL_FEE_BP = 500;
    uint256 internal constant TREASURY_FEE_SPLIT_BP = 5_000;
    uint256 internal constant BP_DIVISOR = 10_000;

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
            6_000, // maxQueueRatioBps (60%)
            7 days // maxAccountingDelay
        );

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

    /// @dev Runs a baseline rebalance with a high target buffer so nothing gets staked.
    function _baselineRebalance() internal {
        vm.prank(address(gov));
        core.setTargetBufferedAssets(1_000_000 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        _fullRebalance();
    }

    /// @dev Sets instantRedemptionFeeBP via governance timelock.
    function _setInstantRedemptionFeeBP(uint256 feeBP) internal {
        bytes memory data = abi.encodeCall(IOllaVault.setInstantRedemptionFeeBP, (feeBP));
        vm.prank(admin);
        gov.schedule(address(vault), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        bytes32 id = gov.hashOperation(address(vault), 0, data, bytes32(0), bytes32(0));
        vm.warp(gov.getTimestamp(id));
        vm.prank(admin);
        gov.execute(address(vault), 0, data, bytes32(0), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
        TEST 4A: INSTANT REDEEM REDUCES BUFFER AVAILABLE FOR QUEUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Instant redemption drains part of the buffer; remaining buffer is sufficient
    ///         for the async queue to finalize on the next rebalance.
    function test_InstantRedeem_ReducesBufferAvailableForQueue() external {
        // --- Setup: alice deposits 100e18, bob deposits 50e18, baseline rebalance ---
        _performDeposit(alice, 100 * DECIMALS);
        _performDeposit(bob, 50 * DECIMALS);
        _baselineRebalance();

        assertEq(vault.bufferedAssets(), 150 * DECIMALS, "pre: buffer should be 150e18");

        // --- Set instant redemption fee = 1% (100 BP) ---
        _setInstantRedemptionFeeBP(100);
        assertEq(vault.instantRedemptionFeeBP(), 100, "fee should be 100 BP");

        // --- alice requests async redeem of 80e18 shares ---
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(80 * DECIMALS, alice, alice);

        // alice burned 80e18 shares → 20e18 remaining
        assertEq(stAztec.balanceOf(alice), 20 * DECIMALS, "alice should have 20e18 shares after request");

        // --- bob instant redeems 50e18 shares (all his shares) ---
        // grossAssets = 50e18 (rate 1:1), fee = 50e18 * 100 / 10000 = 0.5e18, net = 49.5e18
        vm.prank(bob);
        uint256 bobNet = vault.instantRedeem(50 * DECIMALS, bob, 0);

        assertEq(bobNet, 49.5e18, "bob should receive 49.5e18 net");
        assertEq(asset.balanceOf(bob), 49.5e18, "bob asset balance should be 49.5e18");
        assertEq(asset.balanceOf(treasury), 0.5e18, "treasury should receive 0.5e18 fee");
        assertEq(vault.bufferedAssets(), 100 * DECIMALS, "buffer should be 150 - 50 = 100e18");

        // --- Rebalance: finalize alice's 80e18 request (100e18 buffer > 80e18 pending) ---
        _warpPastCooldown();
        _fullRebalance();

        // Queue should be finalized
        IWithdrawalQueue.WithdrawalRequest memory req = withdrawalQueue.getRequest(requestId);
        assertTrue(req.finalized, "alice's request should be finalized");

        // Buffer reduced by finalized amount
        assertEq(vault.bufferedAssets(), 20 * DECIMALS, "buffer should be 100 - 80 = 20e18");

        // --- alice claims her withdrawal ---
        vm.prank(alice);
        uint256 aliceClaimed = vault.claimRequestById(requestId);

        assertEq(aliceClaimed, 80 * DECIMALS, "alice should claim 80e18");
        assertEq(asset.balanceOf(alice), 80 * DECIMALS, "alice asset balance should be 80e18");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 4B: INSTANT REDEEM EXHAUSTS BUFFER — QUEUE CANNOT FINALIZE
    //////////////////////////////////////////////////////////////*/

    /// @notice Instant redemption drains buffer below what the queue needs; head-of-line
    ///         blocking prevents finalization until unstaked funds return.
    function test_InstantRedeem_ExhaustsBuffer_QueueCannotFinalize() external {
        // --- Setup: alice deposits 100e18, bob deposits 100e18 ---
        _performDeposit(alice, 100 * DECIMALS);
        _performDeposit(bob, 100 * DECIMALS);

        // Stake 150e18, keep 50e18 buffer
        vm.prank(address(gov));
        core.setTargetBufferedAssets(50 * DECIMALS);
        stakingManager.setStakeReturnAmount(150 * DECIMALS);
        stakingManager.setTotalStaked(150 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        _fullRebalance();

        assertEq(vault.bufferedAssets(), 50 * DECIMALS, "pre: buffer should be 50e18");

        // --- Set instant redemption fee = 0 for simplicity ---
        _setInstantRedemptionFeeBP(0);

        // --- alice requests async redeem of 80e18 shares ---
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(80 * DECIMALS, alice, alice);

        // --- bob instant redeems 40e18 shares → buffer = 50 - 40 = 10e18 ---
        vm.prank(bob);
        vault.instantRedeem(40 * DECIMALS, bob, 0);

        assertEq(vault.bufferedAssets(), 10 * DECIMALS, "buffer should be 10e18 after instant redeem");
        assertEq(asset.balanceOf(bob), 40 * DECIMALS, "bob should receive 40e18");

        // --- Rebalance: finalize tries 80e18 but only 10e18 available → head-of-line blocking ---
        _warpPastCooldown();
        stakingManager.clearStakeReturnAmount();
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        _fullRebalance();

        // alice's request should NOT be finalized
        IWithdrawalQueue.WithdrawalRequest memory req = withdrawalQueue.getRequest(requestId);
        assertFalse(req.finalized, "alice's request should NOT be finalized (head-of-line blocking)");

        // Buffer unchanged (nothing consumed by finalization)
        assertEq(vault.bufferedAssets(), 10 * DECIMALS, "buffer should remain 10e18");

        // Rebalance completes to Done
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete to Done");

        // --- Follow-up: simulate unstaked funds returning (80e18) ---
        asset.mint(address(stakingManager), 80 * DECIMALS);
        stakingManager.setUnstakedAmount(80 * DECIMALS);
        stakingManager.setTotalStaked(70 * DECIMALS); // 150 - 80 = 70

        _warpPastCooldown();
        _fullRebalance();

        // alice's request should now be finalized
        req = withdrawalQueue.getRequest(requestId);
        assertTrue(req.finalized, "alice's request should be finalized after unstake");

        // --- alice claims ---
        vm.prank(alice);
        uint256 aliceClaimed = vault.claimRequestById(requestId);
        assertEq(aliceClaimed, 80 * DECIMALS, "alice should claim 80e18");
        assertEq(asset.balanceOf(alice), 80 * DECIMALS, "alice asset balance should be 80e18");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 4C: INSTANT REDEEM FEE GOES TO TREASURY
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies fee calculation: grossAssets * feeBP / 10_000 to treasury,
    ///         net = grossAssets - fee to recipient.
    function test_InstantRedeem_FeeGoesToTreasury() external {
        // --- Setup: alice deposits 100e18, baseline rebalance ---
        _performDeposit(alice, 100 * DECIMALS);
        _baselineRebalance();

        // --- Set instant redemption fee = 5% (500 BP) ---
        _setInstantRedemptionFeeBP(500);

        // --- alice instant redeems 20e18 shares ---
        // grossAssets = 20e18 (rate 1:1), fee = 1e18, net = 19e18
        uint256 rate = core.exchangeRate();

        vm.expectEmit(true, true, true, true, address(vault));
        emit InstantRedemption(alice, alice, 20 * DECIMALS, 20 * DECIMALS, 1 * DECIMALS, 19 * DECIMALS, rate);

        vm.prank(alice);
        uint256 net = vault.instantRedeem(20 * DECIMALS, alice, 0);

        // --- Assertions ---
        assertEq(net, 19 * DECIMALS, "net should be 19e18");
        assertEq(asset.balanceOf(alice), 19 * DECIMALS, "alice should receive 19e18");
        assertEq(asset.balanceOf(treasury), 1 * DECIMALS, "treasury should receive 1e18 fee");
        assertEq(vault.bufferedAssets(), 80 * DECIMALS, "buffer should be 100 - 20 = 80e18");
        assertEq(stAztec.totalSupply(), 80 * DECIMALS, "supply should be 100 - 20 = 80e18");
        assertEq(stAztec.balanceOf(alice), 80 * DECIMALS, "alice shares should be 80e18");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 4D: INSTANT REDEEM AFTER RATE INCREASE — CORRECT CONVERSION
    //////////////////////////////////////////////////////////////*/

    /// @notice After rewards increase the exchange rate above 1:1, instant redemption
    ///         correctly converts shares to assets at the new rate.
    function test_InstantRedeem_AfterRateIncrease_CorrectConversion() external {
        // --- Setup: alice deposits 100e18, baseline rebalance (high buffer, nothing staked) ---
        _performDeposit(alice, 100 * DECIMALS);
        _baselineRebalance();

        // --- Simulate 25e18 rewards, rebalance to update rate ---
        stakingManager.setHarvestedRewards(25 * DECIMALS);
        stakingManager.setClaimableRewards(1);
        _warpPastCooldown();
        _fullRebalance();

        // Rate should be > 1e18 now (rewards increase totalAssets, fee minting increases supply slightly)
        uint256 rate = core.exchangeRate();
        assertGt(rate, 1e18, "rate should be > 1e18 after rewards");

        uint256 supplyBefore = stAztec.totalSupply();

        // --- bob deposits 50e18 → gets shares at new rate ---
        uint256 bobShares = _performDeposit(bob, 50 * DECIMALS);
        assertLt(bobShares, 50 * DECIMALS, "bob should get fewer than 50e18 shares at rate > 1");

        // --- Set instant redemption fee = 5% (500 BP) ---
        _setInstantRedemptionFeeBP(500);

        // --- bob instant redeems ALL his shares ---
        uint256 bobGrossAssets = core.convertToAssets(bobShares);
        uint256 expectedFee = bobGrossAssets * 500 / BP_DIVISOR;
        uint256 expectedNet = bobGrossAssets - expectedFee;

        vm.prank(bob);
        uint256 bobNet = vault.instantRedeem(bobShares, bob, 0);

        // --- Assertions ---
        assertEq(bobNet, expectedNet, "bob net should match expected");
        assertEq(asset.balanceOf(bob), expectedNet, "bob balance should equal net assets");
        assertLt(asset.balanceOf(bob), 50 * DECIMALS, "bob should receive less than 50e18 (paid fee)");
        assertEq(asset.balanceOf(treasury), expectedFee, "treasury should receive fee");

        // stAztec supply should return to pre-bob level
        assertEq(stAztec.totalSupply(), supplyBefore, "supply should return to pre-bob level");
        assertEq(stAztec.balanceOf(bob), 0, "bob should have 0 shares after full redeem");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 4E: INSTANT REDEEM — INSUFFICIENT BUFFER REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Attempting to instant redeem more than the available buffer reverts
    ///         with OllaVault__InsufficientLiquidity and no state changes.
    function test_InstantRedeem_InsufficientBuffer_Reverts() external {
        // --- Setup: alice deposits 100e18, stake 90e18 → buffer = 10e18 ---
        _performDeposit(alice, 100 * DECIMALS);

        vm.prank(address(gov));
        core.setTargetBufferedAssets(10 * DECIMALS);
        stakingManager.setStakeReturnAmount(90 * DECIMALS);
        stakingManager.setTotalStaked(90 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        _fullRebalance();

        assertEq(vault.bufferedAssets(), 10 * DECIMALS, "pre: buffer should be 10e18");

        // --- Set instant redemption fee = 0 ---
        _setInstantRedemptionFeeBP(0);

        // --- Snapshot state ---
        uint256 aliceSharesBefore = stAztec.balanceOf(alice);
        uint256 bufferBefore = vault.bufferedAssets();
        uint256 supplyBefore = stAztec.totalSupply();

        // --- alice tries instant redeem 20e18 shares → grossAssets = 20e18 > buffer 10e18 ---
        vm.expectRevert(
            abi.encodeWithSelector(IOllaVault.OllaVault__InsufficientLiquidity.selector, 20 * DECIMALS, 10 * DECIMALS)
        );
        vm.prank(alice);
        vault.instantRedeem(20 * DECIMALS, alice, 0);

        // --- Verify no state changes ---
        assertEq(stAztec.balanceOf(alice), aliceSharesBefore, "alice shares should be unchanged");
        assertEq(vault.bufferedAssets(), bufferBefore, "buffer should be unchanged");
        assertEq(stAztec.totalSupply(), supplyBefore, "supply should be unchanged");
        assertEq(asset.balanceOf(alice), 0, "alice should have received no assets");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 4F: INSTANT AND ASYNC REDEEM — SAME USER — SAME BLOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice A single user can mix instant and async redemption in the same block
    ///         with correct accounting and conservation of value.
    function test_InstantAndAsyncRedeem_SameUser_SameBlock() external {
        // --- Setup: alice deposits 200e18, baseline rebalance ---
        _performDeposit(alice, 200 * DECIMALS);
        _baselineRebalance();

        assertEq(vault.bufferedAssets(), 200 * DECIMALS, "pre: buffer should be 200e18");
        assertEq(stAztec.balanceOf(alice), 200 * DECIMALS, "pre: alice should have 200e18 shares");

        // --- Set instant redemption fee = 5% (500 BP) ---
        _setInstantRedemptionFeeBP(500);

        // --- Same block: instant redeem 50e18, then request async redeem 50e18 ---
        // Instant: grossAssets = 50e18, fee = 2.5e18, net = 47.5e18
        vm.prank(alice);
        uint256 instantNet = vault.instantRedeem(50 * DECIMALS, alice, 0);
        assertEq(instantNet, 47.5e18, "instant net should be 47.5e18");

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(50 * DECIMALS, alice, alice);

        // --- Assertions after both operations ---
        assertEq(stAztec.balanceOf(alice), 100 * DECIMALS, "alice should have 100e18 shares");
        assertEq(asset.balanceOf(alice), 47.5e18, "alice assets should be 47.5e18 from instant");
        assertEq(vault.bufferedAssets(), 150 * DECIMALS, "buffer should be 200 - 50 = 150e18");
        assertEq(asset.balanceOf(treasury), 2.5e18, "treasury should have 2.5e18 fee");

        // --- Rebalance: finalize async request ---
        _warpPastCooldown();
        _fullRebalance();

        IWithdrawalQueue.WithdrawalRequest memory req = withdrawalQueue.getRequest(requestId);
        assertTrue(req.finalized, "alice's async request should be finalized");

        // --- alice claims ---
        vm.prank(alice);
        uint256 asyncClaimed = vault.claimRequestById(requestId);
        assertEq(asyncClaimed, 50 * DECIMALS, "alice should claim 50e18 from async");

        // --- Conservation check ---
        uint256 aliceTotalReceived = asset.balanceOf(alice); // 47.5 + 50 = 97.5
        uint256 aliceRemainingShareValue = core.convertToAssets(stAztec.balanceOf(alice)); // 100e18 at 1:1
        uint256 feeCollected = asset.balanceOf(treasury); // 2.5

        assertEq(aliceTotalReceived, 97.5e18, "alice total received should be 97.5e18");
        assertEq(aliceRemainingShareValue, 100 * DECIMALS, "alice remaining share value should be 100e18");
        assertEq(feeCollected, 2.5e18, "fee collected should be 2.5e18");

        // total out + fee + remaining value = total deposited
        assertEq(
            aliceTotalReceived + feeCollected + aliceRemainingShareValue,
            200 * DECIMALS,
            "conservation: total_out + fee + remaining_value should equal 200e18"
        );
    }
}
