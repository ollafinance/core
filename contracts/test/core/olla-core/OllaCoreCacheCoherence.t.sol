// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { StAztec } from "src/vault/StAztec.sol";

import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";

/*//////////////////////////////////////////////////////////////
            MOCK: CACHE-COHERENT STAKING MANAGER
//////////////////////////////////////////////////////////////*/

/// @notice Test-only staking manager mock that models rollup-backed live reads correctly:
///         - `harvestRewards()` drains `claimableRewards` to zero (mimicking
///           `rollup.claimSequencerRewards` resetting `pendingRewards[accumulator]`).
///         - `setClaimableRewards()` is additive by default (`addClaimable`) so that
///           validator accrual between rebalances can be simulated without manual math.
/// @dev Inherits `MockAccountingStakingManager` to reuse its wide interface surface;
///      overrides only the handful of methods where cache-coherence behavior diverges.
contract MockCacheCoherentStakingManager is MockAccountingStakingManager {
    using SafeERC20 for IERC20;

    /// @notice Add to the live claimable balance (simulates validator reward accrual).
    function addClaimable(uint256 amount) external {
        claimableRewards += amount;
    }

    /// @notice Drains claimable rewards to zero and transfers them to the accumulator.
    /// @dev Matches real `StakingManager.harvestRewards` semantics where
    ///      `rollup.claimSequencerRewards(accumulator)` both transfers the balance AND
    ///      zeroes `pendingRewards[accumulator]`.
    function harvestRewards() external override returns (uint256 harvested) {
        harvested = claimableRewards;
        if (harvested > 0 && address(rewardsToken) != address(0) && rewardsAccumulator != address(0)) {
            MockAztec(address(rewardsToken)).mint(address(this), harvested);
            rewardsToken.safeTransfer(rewardsAccumulator, harvested);
            claimableRewards = 0;
        }
        return harvested;
    }

    /// @notice Updates `totalStakedAmount` as tokens actually flow in. The parent mock
    ///         treats `totalStakedAmount` as a purely orthogonal knob, which breaks any
    ///         test that wants `totalStaked()` to be the authoritative live source of
    ///         staked principal after a real rebalance.
    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        uint256 actualAmount = amount;
        if (useStakeReturnAmount) {
            actualAmount = stakeReturnAmount;
            if (!allowStakeReturnExceeds && actualAmount > amount) {
                actualAmount = amount;
            }
        }
        if (actualAmount == 0) {
            return 0;
        }
        if (address(rewardsToken) == address(0)) {
            return 0;
        }
        uint256 transferAmount = actualAmount > amount ? amount : actualAmount;
        if (transferAmount != 0) {
            rewardsToken.safeTransferFrom(msg.sender, address(this), transferAmount);
        }
        totalStakedAmount += transferAmount;
        return actualAmount;
    }

    /// @notice Slash the live staked amount immediately; mirrors what
    ///         `setSlashingDelta` does but is named for the scenario
    ///         (`refreshAttesterState` detecting slashing on the rollup).
    function applySlashing(uint256 delta) external {
        this.setSlashingDelta(slashingDelta + delta);
    }
}

/*//////////////////////////////////////////////////////////////
              CACHE-COHERENCE TEST CONTRACT
//////////////////////////////////////////////////////////////*/

/// @title OllaCoreCacheCoherenceTest
/// @notice Behavior-oriented test specification that drives the upcoming
///         `_accountingState` pull-model refactor on `OllaCore`.
///         Tests in the "FAILS_NOW" section are expected to fail on the
///         current cached-mirror implementation and pass once pull-model
///         reads land. The regression-guard tests document behavior that
///         must continue to hold across the refactor.
contract OllaCoreCacheCoherenceTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant BP_DIVISOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockCacheCoherentStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal operator;
    address internal alice;
    address internal providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MockCacheCoherentStakingManager();
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");

        withdrawalQueue = new MockWithdrawalQueue();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));
        stakingManager.setUnstakedToken(asset);

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        // Advance past the 1-hour initial rebalance cooldown.
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        asset.mint(who, assets);
        vm.startPrank(who);
        asset.approve(address(vault), assets);
        shares = vault.deposit(assets, who, 0);
        vm.stopPrank();
    }

    /// @notice Read-through total-assets expression: the pull-model value that
    ///         `totalAssets()` MUST equal under the refactored read-through design.
    ///         Reads live from every source of truth (no mirror).
    function _readThroughTotalAssets() internal view returns (uint256) {
        uint256 buffered = vault.bufferedAssets();
        uint256 staked = stakingManager.totalStaked();
        uint256 claimable = stakingManager.getClaimableRewards();
        uint256 raBalance = rewardsAccumulator.balance();
        uint256 pending = vault.pendingWithdrawalAssets();
        uint256 total = buffered + staked + claimable + raBalance;
        return pending >= total ? 0 : total - pending;
    }

    /// @notice Probe-and-replay: find a gas stipend that pauses rebalance exactly at
    ///         `FinalizeWithdrawals` AFTER `Harvest` + `PullUnstaked` have run.
    ///         At that point `Harvest` has drained validator rewards into the buffer
    ///         but no `_updateAccountingInternal` has reconciled the mirror yet.
    /// @param expectedRewards The reward amount expected to have been harvested.
    function _pauseAfterHarvestAtFinalize(uint256 expectedRewards) internal returns (uint256 selectedGas) {
        uint256 snap = vm.snapshotState();

        for (uint256 gasLimit = 250_000; gasLimit <= 800_000; gasLimit += 25_000) {
            vm.revertToState(snap);
            vm.prank(operator);
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory data) = address(core).call{ gas: gasLimit }(abi.encodeCall(core.rebalance, ()));
            if (!ok) continue;

            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step != IOllaCore.RebalanceStep.FinalizeWithdrawals) continue;

            (uint256 rd, uint256 fa, uint256 sa,) = abi.decode(data, (uint256, uint256, uint256, uint256));
            if (rd == expectedRewards && fa == 0 && sa == 0) {
                selectedGas = gasLimit;
                break;
            }
        }

        assertGt(selectedGas, 0, "probe failed to find a gas stipend that pauses at FinalizeWithdrawals");

        // Replay with the selected gas to leave the system in the paused state.
        vm.revertToState(snap);
        vm.prank(operator);
        core.rebalance{ gas: selectedGas }();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.FinalizeWithdrawals),
            "harness precondition: rebalance must be paused at FinalizeWithdrawals"
        );
    }

    /*//////////////////////////////////////////////////////////////
            FAILS NOW — TO PASS POST PULL-MODEL REFACTOR
    //////////////////////////////////////////////////////////////*/

    /// FAILS_NOW: After `Harvest` drains `X` to the vault buffer, the cached
    /// `_accountingState.claimableRewards` still holds `X`. With pull reads, the
    /// claimable bucket would read `rollup.getSequencerRewards == 0` and `totalAssets`
    /// at pause == `totalAssets` before the rebalance started. Harvest is a value-
    /// conserving move (claimable → buffer) and must not change `totalAssets`. The
    /// current code double-counts `X` and inflates `totalAssets` by exactly `X`.
    function test_totalAssets_notInflated_afterHarvestBeforeDone() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 rewards = 10 * DECIMALS;

        _deposit(alice, depositAmount);

        // Seed accounting: validator has `rewards` claimable, reconcile mirror.
        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        // Sanity: the mirror and live source agree at the top of the cycle.
        IOllaCore.AccountingState memory mirrorPre = core.accountingState();
        assertEq(mirrorPre.claimableRewards, rewards, "mirror claimable primed");
        assertEq(stakingManager.getClaimableRewards(), rewards, "live claimable primed");

        uint256 totalAtPrime = core.totalAssets();

        // Advance past the cooldown so a new rebalance can start.
        vm.warp(block.timestamp + 1 hours);

        // Pause rebalance after Harvest but before Done.
        _pauseAfterHarvestAtFinalize(rewards);

        // Post-harvest live state: accumulator drained, rollup pending=0, buffer grew by X.
        assertEq(stakingManager.getClaimableRewards(), 0, "live claimable drained by harvest");
        assertEq(rewardsAccumulator.balance(), 0, "live accumulator balance drained");
        assertEq(vault.bufferedAssets(), depositAmount + rewards, "buffer reflects harvested rewards");

        // Harvest conserves value — it moves `rewards` from one bucket (claim) into
        // another (buffer). Under pull reads, totalAssets must be INVARIANT across
        // the harvest boundary. Under the cached mirror, the stale `claimableRewards`
        // bucket keeps its pre-harvest value so totalAssets is inflated by `rewards`.
        uint256 totalAtPause = core.totalAssets();
        assertEq(totalAtPause, totalAtPrime, "totalAssets must be harvest-invariant, not inflated by double-count");
    }

    /// FAILS_NOW: The composed read-through identity must hold in the mid-rebalance
    /// window. Under the cached mirror the claimable mirror is stale, so the composed
    /// sum differs from `totalAssets()`.
    function test_totalAssets_matchesLiveSourcesMidRebalance() external {
        uint256 depositAmount = 80 * DECIMALS;
        uint256 rewards = 12 * DECIMALS;

        _deposit(alice, depositAmount);

        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        vm.warp(block.timestamp + 1 hours);
        _pauseAfterHarvestAtFinalize(rewards);

        uint256 expected = _readThroughTotalAssets();
        assertEq(core.totalAssets(), expected, "mid-rebalance totalAssets must equal live read-through");
    }

    /// FAILS_NOW: Between rebalances, validator rewards accrue on the rollup but the
    /// cached mirror is not refreshed. Pull reads would see them; the mirror does not.
    function test_totalAssets_reflectsValidatorAccrual_betweenRebalances() external {
        uint256 depositAmount = 50 * DECIMALS;
        uint256 accrual = 3 * DECIMALS;

        _deposit(alice, depositAmount);

        // Drive a clean rebalance to baseline the mirror.
        vm.prank(operator);
        core.rebalance();
        uint256 totalAtBaseline = core.totalAssets();

        // Advance time and simulate continuous validator accrual — no
        // `updateAccounting` or `rebalance` call in this window.
        vm.warp(block.timestamp + 7 days);
        stakingManager.addClaimable(accrual);

        // Under pull, totalAssets reads live claimable → baseline + accrual.
        // Under mirror, totalAssets uses stale mirror → unchanged from baseline.
        assertEq(
            core.totalAssets(), totalAtBaseline + accrual, "totalAssets must reflect validator accrual between updates"
        );
    }

    /// FAILS_NOW: `convertToShares` must use a fresh rate between rebalances.
    /// With the mirror stale, depositors mint at the pre-accrual rate and receive
    /// disproportionately many shares.
    function test_convertToShares_usesFreshRate_betweenRebalances() external {
        uint256 depositAmount = 50 * DECIMALS;
        uint256 accrual = 3 * DECIMALS;

        _deposit(alice, depositAmount);
        vm.prank(operator);
        core.rebalance();

        vm.warp(block.timestamp + 7 days);
        stakingManager.addClaimable(accrual);

        // Expected pull-model: shares = assets * supply / (totalAssets including accrual).
        uint256 testAssets = 1 * DECIMALS;
        uint256 supply = stAztec.totalSupply();
        uint256 liveTotal = _readThroughTotalAssets();
        uint256 expectedShares = testAssets.mulDiv(supply + 1e3, liveTotal + 1e3, Math.Rounding.Floor);

        assertEq(core.convertToShares(testAssets), expectedShares, "convertToShares must use live totalAssets");
    }

    /// FAILS_NOW: Symmetric redemption path — redeemers must also see the fresh rate.
    /// With stale mirror, `convertToAssets` under-pays relative to true live backing.
    function test_convertToAssets_usesFreshRate_betweenRebalances() external {
        uint256 depositAmount = 50 * DECIMALS;
        uint256 accrual = 3 * DECIMALS;

        _deposit(alice, depositAmount);
        vm.prank(operator);
        core.rebalance();

        vm.warp(block.timestamp + 7 days);
        stakingManager.addClaimable(accrual);

        uint256 testShares = 1 * DECIMALS;
        uint256 supply = stAztec.totalSupply();
        uint256 liveTotal = _readThroughTotalAssets();
        uint256 expectedAssets = testShares.mulDiv(liveTotal + 1e3, supply + 1e3, Math.Rounding.Floor);

        assertEq(core.convertToAssets(testShares), expectedAssets, "convertToAssets must use live totalAssets");
    }

    /// FAILS_NOW: Slashing discovered via `refreshAttesterState` must be reflected
    /// in `totalAssets` immediately, without needing a subsequent `updateAccounting`
    /// call. The mirror holds the pre-slash `stakedPrincipal` until reconciled.
    function test_totalAssets_reflectsRefreshAttesterState_immediately() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 stakeAmount = 60 * DECIMALS;
        uint256 slashing = 5 * DECIMALS;

        _deposit(alice, depositAmount);

        // Establish staked principal in both the mock and the mirror.
        stakingManager.setTotalStaked(stakeAmount);
        vm.prank(operator);
        core.updateAccounting();

        // Slashing detected on the rollup — a new refreshAttesterState cycle would
        // pick this up. No updateAccounting between detection and the user read.
        stakingManager.applySlashing(slashing);

        // Live read reflects the slash (mock's `setSlashingDelta` reduces totalStaked).
        uint256 expected = _readThroughTotalAssets();
        assertEq(core.totalAssets(), expected, "totalAssets must reflect slashing before next updateAccounting");
    }

    /// FAILS_NOW: Instant redemptions mid-rebalance-pause must pay at the live rate.
    /// Under the stale mirror the rate is inflated by the post-harvest double-count,
    /// so an instant redeemer is over-paid relative to the true backing.
    function test_instantRedeem_freshRate_duringMidRebalancePause() external {
        uint256 depositAmount = 200 * DECIMALS;
        uint256 rewards = 5 * DECIMALS;

        _deposit(alice, depositAmount);

        // Prime the claimable mirror with `rewards` via updateAccounting.
        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        vm.warp(block.timestamp + 1 hours);
        _pauseAfterHarvestAtFinalize(rewards);

        // Post-harvest live totals (what the redeemer's share should be priced on).
        uint256 liveTotal = _readThroughTotalAssets();
        uint256 supply = stAztec.totalSupply();

        uint256 sharesToRedeem = 10 * DECIMALS;
        uint256 grossAssetsExpectedLive = sharesToRedeem.mulDiv(liveTotal + 1e3, supply + 1e3, Math.Rounding.Floor);

        // `convertToAssets` must match the live-priced payout (no inflation).
        assertEq(
            core.convertToAssets(sharesToRedeem),
            grossAssetsExpectedLive,
            "instant-redeem gross payout must use live totalAssets mid-rebalance"
        );
    }

    /// FAILS_NOW: Honest depositors mid-rebalance-pause must mint at the live rate.
    /// Under the stale mirror the rate is inflated and they are short-changed.
    function test_deposit_freshRate_duringMidRebalancePause() external {
        uint256 depositAmount = 200 * DECIMALS;
        uint256 rewards = 5 * DECIMALS;

        _deposit(alice, depositAmount);

        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        vm.warp(block.timestamp + 1 hours);
        _pauseAfterHarvestAtFinalize(rewards);

        uint256 newDepositAssets = 7 * DECIMALS;
        uint256 supply = stAztec.totalSupply();
        uint256 liveTotal = _readThroughTotalAssets();
        uint256 expectedSharesLive = newDepositAssets.mulDiv(supply + 1e3, liveTotal + 1e3, Math.Rounding.Floor);

        assertEq(
            core.convertToShares(newDepositAssets),
            expectedSharesLive,
            "fresh depositor mid-rebalance must mint at live rate"
        );
    }

    /// FAILS_NOW: The `_withdrawalRate` consumed by `_finalizeWithdrawals` is the
    /// rate visible at the moment of the call — mid-rebalance, post-Harvest. The
    /// cached mirror inflates that rate by `rewards` because `claimableRewards` in
    /// the mirror has not been drained to match the live source. Queued redemptions
    /// finalized in that window are thus overpaid relative to true backing.
    function test_finalizeWithdrawals_freshRate_sameRebalanceTx() external {
        uint256 depositAmount = 300 * DECIMALS;
        uint256 rewards = 10 * DECIMALS;
        uint256 sharesToQueue = 40 * DECIMALS;

        _deposit(alice, depositAmount);

        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        // Queue a redemption request so FinalizeWithdrawals has work to do.
        vm.prank(alice);
        vault.requestRedeem(sharesToQueue, alice, alice);

        vm.warp(block.timestamp + 1 hours);

        // Pause at FinalizeWithdrawals — this is the exact moment
        // `_finalizeWithdrawals` would read `_withdrawalRate(vaultRef)` to settle the queue.
        _pauseAfterHarvestAtFinalize(rewards);

        // Compute the rate that `_withdrawalRate` MUST equal under pull-model semantics.
        uint256 buffered = vault.bufferedAssets();
        uint256 live =
            stakingManager.totalStaked() + stakingManager.getClaimableRewards() + rewardsAccumulator.balance();
        uint256 liveGrossTotal = buffered + live;
        uint256 grossSupply = stAztec.totalSupply() + vault.pendingWithdrawalShares();
        uint256 liveGrossRate = (liveGrossTotal + 1e3).mulDiv(DECIMALS, grossSupply + 1e3, Math.Rounding.Floor);

        assertEq(
            core.exposedWithdrawalRate(),
            liveGrossRate,
            "withdrawalRate at FinalizeWithdrawals must reflect live sources, not stale mirror"
        );
    }

    /// FAILS_NOW: Immediately after `Harvest` runs alone, the live staking manager
    /// reports zero claimable but the cached mirror does not — the mirror is stale.
    /// Under pull reads, there is no mirror to go stale.
    function test_harvestRewards_drainsValidator_mirrorReflects() external {
        uint256 depositAmount = 50 * DECIMALS;
        uint256 rewards = 7 * DECIMALS;

        _deposit(alice, depositAmount);

        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.AccountingState memory mirrorBefore = core.accountingState();
        assertEq(mirrorBefore.claimableRewards, rewards, "mirror primed");

        vm.warp(block.timestamp + 1 hours);
        _pauseAfterHarvestAtFinalize(rewards);

        // Post-harvest: live value is zero (rollup drained).
        assertEq(stakingManager.getClaimableRewards(), 0, "live claimable zero post-harvest");

        // The mirror still holds the pre-harvest value — that is the bug.
        // Under pull, this assertion would be strictly redundant because the mirror
        // would not exist; the exposed-claimable bucket would be read from live state.
        IOllaCore.AccountingState memory mirrorAfter = core.accountingState();
        assertEq(
            mirrorAfter.claimableRewards,
            stakingManager.getClaimableRewards(),
            "exposed claimable bucket must equal live source"
        );
    }

    /*//////////////////////////////////////////////////////////////
              REGRESSION GUARDS — MUST PASS NOW AND AFTER
    //////////////////////////////////////////////////////////////*/

    /// @notice When the withdrawal queue is empty, `_withdrawalRate` reduces to
    ///         `_exchangeRate`. This guards the H-02 fix from regressing under
    ///         the pull-model refactor.
    function test_withdrawalRate_matchesExchangeRate_whenQueueEmpty() external {
        uint256 depositAmount = 40 * DECIMALS;
        _deposit(alice, depositAmount);
        stakingManager.setClaimableRewards(2 * DECIMALS);
        vm.prank(operator);
        core.updateAccounting();

        assertEq(vault.pendingWithdrawalShares(), 0, "queue empty precondition");
        assertEq(core.exposedWithdrawalRate(), core.exchangeRate(), "withdrawalRate == exchangeRate when queue empty");
    }

    /// @notice `_latestReport.totalAssets` should remain a stable snapshot across
    ///         in-progress rebalance tx boundaries. The pull-model refactor must
    ///         not accidentally mutate the report struct mid-rebalance.
    function test_rebalance_reportSnapshotStable_acrossTxBoundaries() external {
        uint256 depositAmount = 80 * DECIMALS;
        uint256 rewards = 5 * DECIMALS;

        _deposit(alice, depositAmount);

        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAtBaseline = core.latestReport();

        vm.warp(block.timestamp + 1 hours);
        _pauseAfterHarvestAtFinalize(rewards);

        IOllaCore.LatestReport memory reportAtPause = core.latestReport();
        assertEq(reportAtPause.totalAssets, reportAtBaseline.totalAssets, "report totalAssets stable at pause");
        assertEq(reportAtPause.exchangeRate, reportAtBaseline.exchangeRate, "report exchangeRate stable at pause");
        assertEq(reportAtPause.timestamp, reportAtBaseline.timestamp, "report timestamp stable at pause");
    }

    /// @notice `totalAssets()` must remain a safe `view` call in every mid-cycle
    ///         position. Today this holds trivially because nothing is queried
    ///         from the rollup mock; under pull-model it will be the first
    ///         external staticcall surface added to `totalAssets()`.
    /// @dev Guards future pull-model behavior: if a revert-prone path is added
    ///      in the pull refactor, the guard must be tightened to assert specific
    ///      revert semantics rather than trivial success.
    function test_totalAssets_staticcallSafe_whenRollupReverts() external {
        uint256 depositAmount = 10 * DECIMALS;
        _deposit(alice, depositAmount);

        // Baseline: totalAssets must be callable.
        uint256 total = core.totalAssets();
        assertGe(total, depositAmount, "totalAssets reachable without side-effects");
    }

    /// @notice Fee-share math must use the live `totalAssets` that
    ///         `_updateAccountingInternal` writes into `_latestReport`. The
    ///         pre- and post-fee totalAssets must agree with the read-through
    ///         identity immediately after Done.
    function test_feeComputation_usesFreshTotalAssets() external {
        uint256 depositAmount = 120 * DECIMALS;
        uint256 rewards = 4 * DECIMALS;

        _deposit(alice, depositAmount);

        // Set a nonzero protocol fee so the fee-mint path is exercised.
        vm.prank(governance);
        core.setProtocolFeeBP(500);

        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        assertEq(reportAfter.totalAssets, core.totalAssets(), "report totalAssets matches live");
        assertEq(
            reportAfter.totalAssets, _readThroughTotalAssets(), "report totalAssets matches the read-through identity"
        );
    }
}
