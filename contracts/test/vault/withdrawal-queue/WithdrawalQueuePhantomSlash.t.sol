// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

/// @title WithdrawalQueuePhantomSlashTest
/// @notice Specifies the required behaviour of the WithdrawalQueue slashing-adjustment gate under
///         heterogeneous queue rates (different per-request rates due to reward accrual between
///         requests).
///
/// @dev The gate at WithdrawalQueue.sol:206 compares `currentRate` (passed by OllaCore at finalize
///      via `_withdrawalRate`) against `request.rate` (stored by OllaVault at request time). For
///      the gate to discriminate real slashing from benign reward accrual, both sides must use the
///      same per-share-backing formula. The suite pins down:
///
///      - test_Finalize_NoSlashHeterogeneousQueue_NoPhantomAdjustment: when no slashing has
///        occurred, the gate must stay silent for every request, regardless of how reward accrual
///        is distributed across the pending queue.
///      - test_Finalize_HeterogeneousQueuePlusRealSlash_CleanMagnitude: when a real slash drops
///        the gross rate between Alice's and Bob's locked rates, only Bob's gate fires and his
///        write-down equals his proportional share of the real slash -- no phantom inflation.
///      - test_Finalize_CatastrophicSlash_GateStillFires: regression guard -- a large real slash
///        that drops gross rate below every locked rate must still clamp every request.
contract WithdrawalQueuePhantomSlashTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant DEPOSIT = 100 * DECIMALS;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    address internal governance;
    address internal operator;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Core behind UUPS proxy, with harness exposing internal accounting hooks.
        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        // Vault behind UUPS proxy.
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));
        stakingManager.setUnstakedToken(asset);

        // Real WithdrawalQueue behind UUPS proxy (this suite exercises the actual gate).
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation),
            abi.encodeCall(WithdrawalQueue.initialize, (address(vault), governance, 180_000))
        );
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.startPrank(governance);
        core.setVault(address(vault));
        core.unpause();
        vault.unpause();
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits `assets` from `owner` and returns the minted shares.
    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    /// @notice Redeem request helper: issues `requestRedeem(shares)` from `owner`.
    function _requestRedeem(address owner, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, owner, owner);
        return requestId;
    }

    /// @notice Shared prefix: two deposits + two requests separated by reward accrual.
    /// @dev After this prefix:
    ///      - supply: 0 (both users burned their 100e18 shares on request)
    ///      - bufferedAssets: 200e18 (both deposits still held, no rebalance)
    ///      - rewardsAccumulatorBalance: 200e18 (two accrual steps of 100e18 each)
    ///      - pendingShares: 200e18, pendingAssets: aliceReq.assetsExpected + bobReq.assetsExpected
    ///      - Alice's locked rate is strictly below Bob's locked rate (the two requests were made
    ///        at different per-share-backing levels due to the intervening reward accrual)
    function _runSharedPrefix()
        internal
        returns (
            uint256 aliceId,
            uint256 bobId,
            IWithdrawalQueue.WithdrawalRequest memory aliceReq,
            IWithdrawalQueue.WithdrawalRequest memory bobReq
        )
    {
        // Step 1: Alice and Bob each deposit 100e18 aztec.
        _deposit(alice, DEPOSIT);
        _deposit(bob, DEPOSIT);

        // Step 2: First reward accrual: rewardsAccumulatorBalance = 100e18, rewardsDelta = 100e18.
        core.exposedApplyAccountingUpdates(0, 100 * DECIMALS, 0, 100 * DECIMALS, 0);

        // Step 3: Alice requests redemption.
        aliceId = _requestRedeem(alice, DEPOSIT);
        aliceReq = withdrawalQueue.getRequest(aliceId);

        // Step 4: Second reward accrual: rewardsAccumulatorBalance = 200e18 total.
        core.exposedApplyAccountingUpdates(0, 200 * DECIMALS, 0, 100 * DECIMALS, 0);

        // Step 5: Bob requests redemption -- at a higher per-share rate than Alice.
        bobId = _requestRedeem(bob, DEPOSIT);
        bobReq = withdrawalQueue.getRequest(bobId);

        // Sanity: heterogeneous locked rates.
        assertLt(aliceReq.rate, bobReq.rate, "prefix sanity: alice rate must be below bob rate");
    }

    /// @notice Simulates a rewards harvest: physical aztec flows from the rewards accumulator
    ///         into the vault. Mints `amount` to the vault and decrements the
    ///         `rewardsAccumulatorBalance` mirror by the same amount, preserving gross total
    ///         assets (and hence the gross withdrawal rate) as seen by Core.
    /// @dev This is the physically-correct funding model for finalize: in the real rebalance flow,
    ///      liquidity delivered to the vault comes either from unstakes (stakedPrincipal --> buffered)
    ///      or from rewards harvests (rewardsAccumulatorBalance --> buffered). Both preserve
    ///      gross backing. Minting aztec to the vault without adjusting a mirror would
    ///      non-physically inflate the gross rate and mask the net/gross divergence this suite
    ///      targets.
    function _harvestIntoVault(uint256 amount) internal {
        IOllaCore.AccountingState memory state = core.accountingState();
        require(state.rewardsAccumulatorBalance >= amount, "harvest > mirror");
        core.exposedApplyAccountingUpdates(
            state.stakedPrincipal,
            state.rewardsAccumulatorBalance - amount,
            state.claimableRewards,
            state.rewardsDelta,
            state.slashingDelta
        );
        asset.mint(address(vault), amount);
        vm.prank(governance);
        vault.reconcileBufferedAssets();
    }

    /// @notice Calls vault.finalizeWithdrawals on behalf of Core, using the gross finalize rate.
    function _finalize(uint256 availableAssets) internal returns (uint256 rateUsed) {
        rateUsed = core.exposedWithdrawalRate();
        vm.prank(address(core));
        vault.finalizeWithdrawals(availableAssets, rateUsed);
        return rateUsed;
    }

    /*//////////////////////////////////////////////////////////////
                            NO-SLASH GATE
    //////////////////////////////////////////////////////////////*/

    /// @notice No slashing has occurred: the gate must not fire for any request.
    /// @dev After the shared prefix the queue holds two requests locked at different rates (Alice
    ///      ~1.5e18, Bob ~2.5e18) with 200e18 of rewards-accumulator backing. A harvest delivers
    ///      liquidity without changing gross backing, so the gross finalize rate (~2.0e18) sits
    ///      between Alice's and Bob's locked rates. Because no slashing has occurred, every
    ///      request must be paid in full: `assetsExpected` untouched and
    ///      `cumulativeSlashingAdjustments` at zero.
    function test_Finalize_NoSlashHeterogeneousQueue_NoPhantomAdjustment() external {
        (
            uint256 aliceId,
            uint256 bobId,
            IWithdrawalQueue.WithdrawalRequest memory aliceReq,
            IWithdrawalQueue.WithdrawalRequest memory bobReq
        ) = _runSharedPrefix();

        // Deliver liquidity via a simulated rewards harvest: physical aztec flows from the
        // accumulator to the vault, bufferedAssets grows and the mirror shrinks by the same
        // amount. No slashing is applied. After harvest: buffered = 400e18, rewardsAcc = 0,
        // grossAssets = 400e18, grossSupply = 200e18 --> grossRate ~= 2.0e18. This is strictly
        // between Alice's locked net rate (~1.5e18) and Bob's locked net rate (~2.5e18), which
        // is exactly the spurious-slash regime the fix targets.
        _harvestIntoVault(200 * DECIMALS);

        _finalize(400 * DECIMALS);

        IWithdrawalQueue.WithdrawalRequest memory aliceFinal = withdrawalQueue.getRequest(aliceId);
        IWithdrawalQueue.WithdrawalRequest memory bobFinal = withdrawalQueue.getRequest(bobId);

        assertTrue(aliceFinal.finalized, "alice request should be finalized");
        assertTrue(bobFinal.finalized, "bob request should be finalized");

        assertEq(
            aliceFinal.assetsExpected, aliceReq.assetsExpected, "alice assetsExpected must be untouched (no slashing)"
        );
        assertEq(bobFinal.assetsExpected, bobReq.assetsExpected, "bob assetsExpected must be untouched (no slashing)");
        assertEq(
            vault.cumulativeSlashingAdjustments(),
            0,
            "cumulativeSlashingAdjustments must be zero when no slashing occurred"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      SLASH + HETEROGENEOUS QUEUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Real slash placing gross rate between Alice's and Bob's locked rates: only Bob's
    ///         gate fires, and his write-down equals his proportional share of the real slash.
    /// @dev `grossRateAtBobRequest` is snapshotted immediately after Bob's request and is the
    ///      rate expected on `bobReq` under the spec. After the slash the gross rate sits between
    ///      Alice's and Bob's locked rates, so only Bob's gate fires. The queue's write-down
    ///      (`bobReq.assetsExpected - clamped payout`) must equal exactly
    ///      `bobReq.shares * (grossRateAtBobRequest - postSlashRate) / 1e18` -- Bob's
    ///      proportional share of the real 80e18 slash, with no phantom component from net/gross
    ///      divergence at request time.
    function test_Finalize_HeterogeneousQueuePlusRealSlash_CleanMagnitude() external {
        (
            uint256 aliceId,
            uint256 bobId,
            IWithdrawalQueue.WithdrawalRequest memory aliceReq,
            IWithdrawalQueue.WithdrawalRequest memory bobReq
        ) = _runSharedPrefix();

        // Snapshot the gross withdrawal rate at Bob's request time, before any slash or harvest.
        // This is the rate the spec associates with `bobReq` and from which
        // `bobReq.assetsExpected` is derived: `bobReq.shares * grossRateAtBobRequest / 1e18`.
        uint256 grossRateAtBobRequest = core.exposedWithdrawalRate();

        // Apply a real slash that drops the rewards-accumulator mirror from 200e18 to 120e18
        // and records 80e18 of slashingDelta. Before harvest: grossAssets = 200 (buffered) +
        // 120 (mirror) = 320e18 against 200e18 of pending shares, so grossRate = 1.6e18
        // (between Alice's ~1.5e18 and Bob's ~2.5e18).
        core.exposedApplyAccountingUpdates(0, 120 * DECIMALS, 0, 0, 80 * DECIMALS);

        uint256 postSlashRate = core.exposedWithdrawalRate();

        // Sanity: postSlashRate must sit strictly between Alice's and Bob's locked rates so that
        // Alice's gate stays silent while Bob's fires.
        assertGt(postSlashRate, aliceReq.rate, "sanity: post-slash rate must be above alice's locked rate");
        assertLt(postSlashRate, bobReq.rate, "sanity: post-slash rate must be below bob's locked rate");

        // Harvest the remaining mirror balance (120e18) into the vault. This delivers physical
        // liquidity (buffered --> 320e18) while preserving grossAssets (and therefore the gross
        // rate at finalize). Buffered 320e18 covers Alice's 150e18 payout + Bob's 160e18 clamped
        // payout = 310e18.
        _harvestIntoVault(120 * DECIMALS);

        uint256 rateUsed = _finalize(400 * DECIMALS);
        assertEq(rateUsed, postSlashRate, "finalize rate sanity: must equal captured postSlashRate");

        IWithdrawalQueue.WithdrawalRequest memory aliceFinal = withdrawalQueue.getRequest(aliceId);
        IWithdrawalQueue.WithdrawalRequest memory bobFinal = withdrawalQueue.getRequest(bobId);

        assertTrue(aliceFinal.finalized, "alice request should be finalized");
        assertTrue(bobFinal.finalized, "bob request should be finalized");

        // Assertion 1: Alice's gate stays silent -- her assetsExpected is untouched.
        assertEq(
            aliceFinal.assetsExpected,
            aliceReq.assetsExpected,
            "alice assetsExpected must be untouched (her locked rate is below post-slash rate)"
        );

        // Assertion 2: Bob's payout equals shares * postSlashRate / 1e18 (gate clamps to gross).
        assertEq(
            bobFinal.assetsExpected,
            (bobReq.shares * postSlashRate) / 1e18,
            "bob assetsExpected must equal shares * postSlashRate / 1e18 after gate clamp"
        );

        // Assertion 3: cumulativeSlashingAdjustments equals Bob's proportional share of the real
        // slash: shares * (grossRateAtBobRequest - postSlashRate) / 1e18. With bobReq.assetsExpected
        // stored as shares * grossRateAtBobRequest / 1e18 per the spec, the queue's write-down
        // (bobReq.assetsExpected - clamped payout) equals exactly this quantity.
        uint256 expectedRealSlashWriteDown = (bobReq.shares * (grossRateAtBobRequest - postSlashRate)) / 1e18;
        assertEq(
            vault.cumulativeSlashingAdjustments(),
            expectedRealSlashWriteDown,
            "cumulativeSlashingAdjustments must equal bob's share of the real slash"
        );
    }

    /*//////////////////////////////////////////////////////////////
                           CATASTROPHIC SLASH
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression guard: a slash large enough to drop gross rate below every locked rate
    ///         must still fire the gate for every request.
    /// @dev Catches any change that removes or neuters the gate.
    function test_Finalize_CatastrophicSlash_GateStillFires() external {
        (
            uint256 aliceId,
            uint256 bobId,
            IWithdrawalQueue.WithdrawalRequest memory aliceReq,
            IWithdrawalQueue.WithdrawalRequest memory bobReq
        ) = _runSharedPrefix();

        // Catastrophic slash: wipe the rewards-accumulator mirror entirely (200e18 --> 0) and
        // record 200e18 of slashingDelta. Gross backing falls from 400e18 to 200e18 against
        // 200e18 of pending shares -- grossRate ~= 1.0e18, below both Alice's (~1.5e18) and
        // Bob's (~2.5e18) locked rates.
        core.exposedApplyAccountingUpdates(0, 0, 0, 0, 200 * DECIMALS);

        uint256 postSlashRate = core.exposedWithdrawalRate();

        // Sanity: postSlashRate must be below Alice's locked rate so BOTH gates fire.
        assertLt(postSlashRate, aliceReq.rate, "sanity: post-slash rate must be below alice's locked rate");

        // No harvest needed: bufferedAssets (200e18) exactly covers the clamped payouts
        // (Alice 100e18 + Bob 100e18 = 200e18 at grossRate 1.0e18). Harvesting is impossible
        // anyway -- the mirror is empty after the slash.
        _finalize(400 * DECIMALS);

        IWithdrawalQueue.WithdrawalRequest memory aliceFinal = withdrawalQueue.getRequest(aliceId);
        IWithdrawalQueue.WithdrawalRequest memory bobFinal = withdrawalQueue.getRequest(bobId);

        assertTrue(aliceFinal.finalized, "alice request should be finalized");
        assertTrue(bobFinal.finalized, "bob request should be finalized");

        // Both payouts reduced below the original assetsExpected.
        assertLt(
            aliceFinal.assetsExpected,
            aliceReq.assetsExpected,
            "alice assetsExpected must be written down below original"
        );
        assertLt(
            bobFinal.assetsExpected, bobReq.assetsExpected, "bob assetsExpected must be written down below original"
        );

        // Each final equals shares * postSlashRate / 1e18 exactly (queue's gate formula).
        assertEq(
            aliceFinal.assetsExpected,
            (aliceReq.shares * postSlashRate) / 1e18,
            "alice assetsExpected must equal shares * postSlashRate / 1e18"
        );
        assertEq(
            bobFinal.assetsExpected,
            (bobReq.shares * postSlashRate) / 1e18,
            "bob assetsExpected must equal shares * postSlashRate / 1e18"
        );

        // Adjustment counter records both write-downs; strictly positive.
        assertGt(
            vault.cumulativeSlashingAdjustments(),
            0,
            "cumulativeSlashingAdjustments must be positive after catastrophic slash"
        );
    }
}
