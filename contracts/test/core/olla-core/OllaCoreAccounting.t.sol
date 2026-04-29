// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaCoreAccountingTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event AccountingUpdated(
        uint256 totalAssets,
        uint256 exchangeRate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares,
        uint256 timestamp
    );
    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);
    event NegativeRewardsPeriod(int256 grossRewardsSigned);
    event RewardsDelta(uint256 delta);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant PROTOCOL_FEE_BP = 500;
    uint256 internal constant TREASURY_FEE_SPLIT_BP = 5_000;
    uint256 internal constant BP_DIVISOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal operator;
    address internal providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        operator = makeAddr("operator");
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            PROTOCOL_FEE_BP,
            TREASURY_FEE_SPLIT_BP,
            governance,
            rewardsAccumulator,
            address(safetyModule)
        );

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

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                           ACCOUNTING STATE
    //////////////////////////////////////////////////////////////*/

    function test_BucketGettersReflectState() external {
        uint256 assets = 10 * DECIMALS;
        uint256 staked = 6 * DECIMALS;
        uint256 rewardsAccumulatorBalance = 4 * DECIMALS;
        uint256 claimableRewards = 3 * DECIMALS;
        uint256 slashingDelta = 1 * DECIMALS;

        _performDeposit(alice, assets);

        // Under pull-model accounting, bucket fields on accountingState() are derived at call
        // time from the owning modules. Drive each field through its live source: stakingManager
        // owns stakedPrincipal/claimableRewards/slashingDelta, and the accumulator's balance() is
        // the single source of truth for rewardsAccumulatorBalance.
        stakingManager.setTotalStaked(staked);
        stakingManager.setClaimableRewards(claimableRewards);
        stakingManager.setSlashingDelta(slashingDelta);
        // setSlashingDelta subtracts (slashingDelta - prior) from totalStakedAmount; restore the
        // target staked amount so the test sees the intended composition.
        stakingManager.setTotalStaked(staked);
        deal(address(asset), address(rewardsAccumulator), rewardsAccumulatorBalance);

        IOllaCore.AccountingState memory accounting = core.accountingState();
        assertEq(vault.bufferedAssets(), assets, "bufferedAssets matches deposited assets");
        assertEq(accounting.stakedPrincipal, staked, "stakedPrincipal matches staked amount");
        assertEq(
            accounting.rewardsAccumulatorBalance,
            rewardsAccumulatorBalance,
            "rewardsAccumulatorBalance matches rewards vault"
        );
        assertEq(accounting.claimableRewards, claimableRewards, "claimableRewards matches claimable rewards");
        assertEq(accounting.slashingDelta, slashingDelta, "slashingDelta matches slashing delta");

        assertEq(
            core.totalAssets(),
            assets + staked + rewardsAccumulatorBalance + claimableRewards,
            "totalAssets sums buckets"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    function test_ComputeNetFlows() external view {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: 12 * DECIMALS,
            cumulativeWithdrawals: 4 * DECIMALS,
            cumulativeSlashingAdjustments: 0,
            latestReportCumulativeDeposits: 5 * DECIMALS,
            latestReportCumulativeWithdrawals: 1 * DECIMALS,
            latestReportCumulativeSlashingAdjustments: 0
        });

        (int256 netFlows, uint256 netDeposits, int256 netWithdrawals) = core.exposedComputeNetFlows(flows);

        assertEq(netDeposits, 7 * DECIMALS, "net deposits");
        assertEq(netWithdrawals, int256(3 * DECIMALS), "net withdrawals");
        assertEq(netFlows, int256(4 * DECIMALS), "net flows");
    }

    /// @notice _computeNetFlows subtracts slashing adjustment delta from netWithdrawals.
    function test_ComputeNetFlows_WithSlashingAdjustments() external view {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: 12 * DECIMALS,
            cumulativeWithdrawals: 10 * DECIMALS,
            cumulativeSlashingAdjustments: 3 * DECIMALS,
            latestReportCumulativeDeposits: 5 * DECIMALS,
            latestReportCumulativeWithdrawals: 2 * DECIMALS,
            latestReportCumulativeSlashingAdjustments: 1 * DECIMALS
        });

        (int256 netFlows, uint256 netDeposits, int256 netWithdrawals) = core.exposedComputeNetFlows(flows);

        // netDeposits = 12 - 5 = 7
        assertEq(netDeposits, 7 * DECIMALS, "net deposits with adjustments");
        // rawNetWithdrawals = 10 - 2 = 8, adjustmentDelta = 3 - 1 = 2, netWithdrawals = 8 - 2 = 6
        assertEq(netWithdrawals, int256(6 * DECIMALS), "net withdrawals reduced by slashing adjustment delta");
        // netFlows = 7 - 6 = 1
        assertEq(netFlows, int256(1 * DECIMALS), "net flows with slashing adjustments");
    }

    /// @notice When slashing adjustment delta exceeds raw netWithdrawals, signed netWithdrawals
    ///         goes negative -- preserving the excess as a positive contribution to netFlows
    ///         instead of dropping it via the previous unsigned clamp.
    function test_ComputeNetFlows_SlashingAdjustmentExceedsWithdrawals() external view {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: 10 * DECIMALS,
            cumulativeWithdrawals: 5 * DECIMALS,
            cumulativeSlashingAdjustments: 4 * DECIMALS,
            latestReportCumulativeDeposits: 5 * DECIMALS,
            latestReportCumulativeWithdrawals: 2 * DECIMALS,
            latestReportCumulativeSlashingAdjustments: 0
        });

        (int256 netFlows, uint256 netDeposits, int256 netWithdrawals) = core.exposedComputeNetFlows(flows);

        // netDeposits = 10 - 5 = 5
        assertEq(netDeposits, 5 * DECIMALS, "net deposits");
        // rawNetWithdrawals = 5 - 2 = 3, adjustmentDelta = 4 - 0 = 4, signed = 3 - 4 = -1
        assertEq(netWithdrawals, -int256(1 * DECIMALS), "net withdrawals negative when adjustment exceeds raw");
        // netFlows = 5 - (-1) = 6 -- excess slashing flows through, no phantom rewards downstream
        assertEq(netFlows, int256(6 * DECIMALS), "net flows preserves excess slashing adjustment");
    }

    /// @notice When slashing adjustment delta equals raw netWithdrawals exactly, netWithdrawals is zero.
    function test_ComputeNetFlows_SlashingAdjustmentEqualsWithdrawals() external view {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: 10 * DECIMALS,
            cumulativeWithdrawals: 5 * DECIMALS,
            cumulativeSlashingAdjustments: 3 * DECIMALS,
            latestReportCumulativeDeposits: 5 * DECIMALS,
            latestReportCumulativeWithdrawals: 2 * DECIMALS,
            latestReportCumulativeSlashingAdjustments: 0
        });

        (int256 netFlows, uint256 netDeposits, int256 netWithdrawals) = core.exposedComputeNetFlows(flows);

        // netDeposits = 10 - 5 = 5
        assertEq(netDeposits, 5 * DECIMALS, "net deposits");
        // rawNetWithdrawals = 5 - 2 = 3, adjustmentDelta = 3 - 0 = 3, 3 == 3 → exactly zero
        assertEq(netWithdrawals, int256(0), "net withdrawals exactly zero when adjustment equals raw");
        // netFlows = 5 - 0 = 5
        assertEq(netFlows, int256(5 * DECIMALS), "net flows when withdrawals exactly cancelled");
    }

    function test_ComputeTotalAssets() external view {
        IOllaCore.AccountingState memory buckets = IOllaCore.AccountingState({
            stakedPrincipal: 4 * DECIMALS,
            rewardsAccumulatorBalance: 2 * DECIMALS,
            claimableRewards: 5 * DECIMALS,
            rewardsDelta: 1 * DECIMALS,
            slashingDelta: 5 * DECIMALS,
            cumulativeRewards: 0
        });

        uint256 totalAssets = core.exposedComputeTotalAssets(buckets, 3 * DECIMALS, 0);

        // stakedPrincipal is net-of-slashing; slashingDelta is informational only
        // total = buffered(3) + staked(4) + ra(2) + claimable(5) = 14
        assertEq(totalAssets, 14 * DECIMALS, "total assets computed");
    }

    function test_ComputeGrossRewards() external view {
        (uint256 grossRewards, int256 grossRewardsSigned) =
            core.exposedComputeGrossRewards(100 * DECIMALS, 130 * DECIMALS, int256(20 * DECIMALS));

        assertEq(grossRewards, 10 * DECIMALS, "gross rewards computed");
        assertEq(grossRewardsSigned, int256(10 * DECIMALS), "gross rewards signed positive");
    }

    function test_ComputeGrossRewards_Negative() external view {
        (uint256 grossRewards, int256 grossRewardsSigned) =
            core.exposedComputeGrossRewards(100 * DECIMALS, 90 * DECIMALS, int256(5 * DECIMALS));

        assertEq(grossRewards, 0, "gross rewards clamped to zero");
        assertEq(grossRewardsSigned, -int256(15 * DECIMALS), "gross rewards signed negative");
    }

    /// @notice When slashing adjustments exceed withdrawals, the period's totalAssets growth is
    ///         fully explained by netDeposits + the excess slashing impact, so gross rewards must
    ///         remain zero. The clamp-to-zero pattern in `_computeNetFlows` violates this and
    ///         silently drops the excess, producing phantom rewards.
    function test_ComputeGrossRewards_NoPhantomRewardsWhenSlashingExceedsWithdrawals() external view {
        uint256 netDeposits = 5 * DECIMALS;
        uint256 rawNetWithdrawals = 3 * DECIMALS;
        uint256 adjustmentsSinceReport = 4 * DECIMALS;
        uint256 oldTotalAssets = 100 * DECIMALS;
        uint256 newTotalAssets = 106 * DECIMALS;

        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: netDeposits,
            cumulativeWithdrawals: rawNetWithdrawals,
            cumulativeSlashingAdjustments: adjustmentsSinceReport,
            latestReportCumulativeDeposits: 0,
            latestReportCumulativeWithdrawals: 0,
            latestReportCumulativeSlashingAdjustments: 0
        });

        (int256 netFlows,,) = core.exposedComputeNetFlows(flows);
        (uint256 grossRewards, int256 grossRewardsSigned) =
            core.exposedComputeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);

        // changeInAssets (+6e18) = netDeposits (+5e18) + droppedExcess (+1e18). No real yield.
        assertEq(grossRewards, 0, "slashing-adjustment excess must not inflate gross rewards");
        assertEq(grossRewardsSigned, 0, "signed gross rewards reflect zero true yield");
    }

    /// @notice Phantom rewards from the slashing-adjustment clamp must not produce protocol fees.
    function test_CalculateProtocolFees_NoExcessFeesWhenSlashingExceedsWithdrawals() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 netDeposits = 5 * DECIMALS;
        uint256 rawNetWithdrawals = 3 * DECIMALS;
        uint256 adjustmentsSinceReport = 4 * DECIMALS;
        uint256 oldTotalAssets = 100 * DECIMALS;
        uint256 newTotalAssets = 106 * DECIMALS;

        _performDeposit(alice, depositAmount);

        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: netDeposits,
            cumulativeWithdrawals: rawNetWithdrawals,
            cumulativeSlashingAdjustments: adjustmentsSinceReport,
            latestReportCumulativeDeposits: 0,
            latestReportCumulativeWithdrawals: 0,
            latestReportCumulativeSlashingAdjustments: 0
        });

        (int256 netFlows,,) = core.exposedComputeNetFlows(flows);
        (uint256 grossRewards,) = core.exposedComputeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        (uint256 feeAssets, uint256 treasuryShares, uint256 providerShares) =
            core.exposedCalculateProtocolFees(grossRewards);

        assertEq(feeAssets, 0, "no fees when no real rewards accrued");
        assertEq(treasuryShares, 0, "no treasury shares from phantom rewards");
        assertEq(providerShares, 0, "no provider shares from phantom rewards");
    }

    /*//////////////////////////////////////////////////////////////
                          ACCOUNTING UPDATES
    //////////////////////////////////////////////////////////////*/

    function test_UpdateAccountingSnapshots() external {
        uint256 depositAmount = 25 * DECIMALS;

        _performDeposit(alice, depositAmount);

        IOllaCore.LatestReport memory reportBefore = core.latestReport();
        IOllaCore.FlowCounters memory flowsBefore = core.flowCounters();
        assertEq(reportBefore.totalAssets, 0, "lastTotalAssets before update");
        assertEq(flowsBefore.latestReportCumulativeDeposits, 0, "latestReportCumulativeDeposits before update");
        assertEq(flowsBefore.latestReportCumulativeWithdrawals, 0, "latestReportCumulativeWithdrawals before update");

        uint256 expectedRate = core.exchangeRate();
        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(core));
        emit AccountingUpdated(depositAmount, expectedRate, 0, int256(depositAmount), 0, 0, 0, expectedTimestamp);
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        IOllaCore.FlowCounters memory flowsAfter = core.flowCounters();
        assertEq(reportAfter.totalAssets, depositAmount, "lastTotalAssets updated");
        assertEq(reportAfter.exchangeRate, expectedRate, "stored exchange rate updated");
        assertEq(flowsAfter.latestReportCumulativeDeposits, depositAmount, "latestReportCumulativeDeposits updated");
        assertEq(flowsAfter.latestReportCumulativeWithdrawals, 0, "latestReportCumulativeWithdrawals updated");
        assertEq(flowsAfter.cumulativeDeposits, depositAmount, "cumulative deposits tracked");
        assertEq(reportAfter.exchangeRate, expectedRate, "latest report exchange rate stored");
        assertEq(reportAfter.timestamp, expectedTimestamp, "report timestamp updated");
    }

    /// @notice updateAccounting persists latestReportCumulativeSlashingAdjustments in the flow counters.
    function test_UpdateAccountingSnapshots_PersistsSlashingAdjustment() external {
        uint256 depositAmount = 50 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Directly set cumulativeSlashingAdjustments on the vault via the mock withdrawal queue.
        // Since MockWithdrawalQueue is used, we simulate slashing by injecting staked + slashing delta
        // into core, then running updateAccounting.
        stakingManager.setTotalStaked(20 * DECIMALS);
        stakingManager.setSlashingDelta(5 * DECIMALS);

        IOllaCore.FlowCounters memory flowsBefore = core.flowCounters();
        assertEq(
            flowsBefore.latestReportCumulativeSlashingAdjustments,
            0,
            "latestReportCumulativeSlashingAdjustments should be zero before update"
        );

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.FlowCounters memory flowsAfter = core.flowCounters();
        // The snapshot should capture the current cumulativeSlashingAdjustments from the vault
        assertEq(
            flowsAfter.latestReportCumulativeSlashingAdjustments,
            flowsAfter.cumulativeSlashingAdjustments,
            "snapshot should equal current cumulativeSlashingAdjustments after updateAccounting"
        );
    }

    /// @notice Verifies that grossRewards and protocol fees are computed correctly when slashing
    ///         adjustments reduce netWithdrawals during the accounting period.
    ///         The key property: grossRewards = max(0, newTotalAssets - oldTotalAssets - netFlows).
    function test_UpdateAccounting_FeesCorrectWithSlashingAdjustment() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Establish baseline accounting
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory report1 = core.latestReport();

        // Create a withdrawal request (increases cumulativeWithdrawals on vault)
        uint256 sharesToRedeem = 20 * DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, alice, alice);

        // Add claimable rewards so grossRewards is positive
        stakingManager.setClaimableRewards(15 * DECIMALS);

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory report2 = core.latestReport();

        // Verify grossRewards formula consistency:
        // grossRewards = max(0, newTotalAssets - oldTotalAssets - netFlows)
        int256 changeInAssets = int256(report2.totalAssets) - int256(report1.totalAssets);
        int256 impliedGrossRewards = changeInAssets - report2.netFlows;
        uint256 expectedGross = impliedGrossRewards > 0 ? uint256(impliedGrossRewards) : 0;

        assertEq(report2.grossRewards, expectedGross, "grossRewards should equal max(0, deltaAssets - netFlows)");
        // netFlows should be negative (withdrawal request with no deposits)
        assertLt(report2.netFlows, 0, "netFlows should be negative with net withdrawals");
        // grossRewards should be positive (rewards added)
        assertGt(report2.grossRewards, 0, "grossRewards should be positive with claimable rewards");
    }

    function test_UpdateAccounting_NetFlowsNegative_NoPhantomRewards() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        core.updateAccounting();

        uint256 sharesToRedeem = 40 * DECIMALS;
        uint256 rate = core.exchangeRate();
        uint256 assetsExpected = sharesToRedeem * rate / DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, alice, alice);

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        assertEq(reportAfter.netFlows, -int256(assetsExpected), "net flows negative");
        // No actual rewards accrued -- pending withdrawal assets are excluded from totalAssets
        // so the formula correctly computes grossRewards = 0 instead of phantom rewards.
        assertEq(reportAfter.grossRewards, 0, "no phantom rewards from withdrawal requests");
        assertEq(reportAfter.totalAssets, depositAmount - assetsExpected, "total assets excludes pending withdrawals");
    }

    function test_UpdateAccounting_GrossRewardsZero_TotalAssetsZero_NoFeeMinting() external {
        uint256 depositAmount = 12 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        core.setProtocolFeeBP(1_000);

        // Move all assets to staking so buffer is empty, then slash everything
        stakingManager.setStakeReturnAmount(depositAmount);
        vm.prank(operator);
        core.rebalance();

        // Mock needs totalStaked set (stake() doesn't auto-update it)
        stakingManager.setTotalStaked(depositAmount);
        stakingManager.setSlashingDelta(depositAmount); // reduces totalStaked to 0

        uint256 supplyBefore = stAztec.totalSupply();
        uint256 treasuryBalanceBefore = stAztec.balanceOf(governance);
        uint256 providerBalanceBefore = stAztec.balanceOf(providerRewardsRecipient);

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        assertEq(reportAfter.grossRewards, 0, "gross rewards zero");
        assertEq(reportAfter.totalAssets, 0, "total assets zero");
        // With +1e3 virtual offset, rate is tiny but non-zero when totalAssets=0 and supply>0
        uint256 expectedRate = uint256(1e3).mulDiv(DECIMALS, supplyBefore + 1e3, Math.Rounding.Floor);
        assertEq(reportAfter.exchangeRate, expectedRate, "exchange rate near-zero with virtual offset");
        assertEq(stAztec.totalSupply(), supplyBefore, "no fee shares minted");
        assertEq(stAztec.balanceOf(governance), treasuryBalanceBefore, "treasury shares unchanged");
        assertEq(stAztec.balanceOf(providerRewardsRecipient), providerBalanceBefore, "provider shares unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                       ACCOUNTING TIMELINESS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateAccountingTimestampMonotonic() external {
        _performDeposit(alice, 5 * DECIMALS);

        vm.prank(operator);
        core.updateAccounting();
        IOllaCore.LatestReport memory firstReport = core.latestReport();
        uint256 firstTimestamp = firstReport.timestamp;

        vm.warp(firstTimestamp + 1);
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory secondReport = core.latestReport();
        uint256 secondTimestamp = secondReport.timestamp;
        assertGt(secondTimestamp, firstTimestamp, "report timestamp should increase");
    }

    function test_UpdateAccounting_RewardDeltaUsesCumulativeAndClaimableRewards() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setHarvestedRewards(3 * DECIMALS);
        vm.prank(operator);
        core.rebalance();
        stakingManager.setClaimableRewards(4 * DECIMALS);

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory firstReport = core.latestReport();
        assertEq(firstReport.rewardsSnapshot, 7 * DECIMALS, "first rewards snapshot stored");

        stakingManager.setHarvestedRewards(2 * DECIMALS);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        core.rebalance();
        stakingManager.setClaimableRewards(9 * DECIMALS);

        // Under pull-model accounting, `accountingState().rewardsDelta` is derived relative to the
        // latest report's rewardsSnapshot. Snapshot the LIVE delta BEFORE updateAccounting() runs
        // to capture what the delta computation consumed, since the report will then advance the
        // rewardsSnapshot and collapse the live delta back to zero.
        IOllaCore.AccountingState memory accountingBefore = core.accountingState();
        IOllaCore.LatestReport memory reportBefore = core.latestReport();
        uint256 currentRewards = accountingBefore.cumulativeRewards + 9 * DECIMALS;
        uint256 expectedDelta =
            currentRewards > reportBefore.rewardsSnapshot ? currentRewards - reportBefore.rewardsSnapshot : 0;
        assertEq(accountingBefore.rewardsDelta, expectedDelta, "live rewards delta reflects cumulative+claimable");
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory secondReport = core.latestReport();
        assertEq(secondReport.rewardsSnapshot, 14 * DECIMALS, "rewards snapshot advanced");
        assertEq(
            secondReport.rewardsSnapshot - reportBefore.rewardsSnapshot,
            expectedDelta,
            "snapshot advancement matches computed delta"
        );
    }

    function test_UpdateAccounting_RewardsDeltaClampsWhenClaimableDecreases() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setClaimableRewards(10 * DECIMALS);
        vm.prank(operator);
        core.updateAccounting();

        stakingManager.setClaimableRewards(5 * DECIMALS);
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        IOllaCore.AccountingState memory accounting = core.accountingState();
        assertEq(accounting.rewardsDelta, 0, "rewards delta clamps to zero");
        assertEq(reportAfter.rewardsSnapshot, 5 * DECIMALS, "rewards snapshot tracks current rewards");
    }

    function test_UpdateAccounting_InvokesSafetyChecks() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 sharesToRedeem = 5 * DECIMALS;
        uint256 rate = core.exchangeRate();
        uint256 assetsExpected = sharesToRedeem * rate / DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, alice, alice);

        uint256 oldRate = 1e18;
        uint256 expectedRate = core.exchangeRate();
        uint256 expectedTotalAssets = core.totalAssets();
        vm.expectCall(address(safetyModule), abi.encodeCall(ISafetyModule.checkAccountingLiveness, ()));
        vm.expectCall(
            address(safetyModule), abi.encodeCall(ISafetyModule.checkQueueRatio, (assetsExpected, expectedTotalAssets))
        );
        vm.expectCall(address(safetyModule), abi.encodeCall(ISafetyModule.checkRateDrop, (oldRate, expectedRate)));
        vm.expectCall(
            address(safetyModule), abi.encodeCall(ISafetyModule.setLatestAccountingTimestamp, (block.timestamp))
        );

        vm.prank(operator);
        core.updateAccounting();
    }

    /*//////////////////////////////////////////////////////////////
                          REBALANCE HARVEST
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_CallsRecordRewardsWithCorrectAmount() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        uint256 totalReceivedBefore = rewardsAccumulator.totalReceived();

        vm.prank(operator);
        core.rebalance();

        uint256 totalReceivedAfter = rewardsAccumulator.totalReceived();
        assertEq(
            totalReceivedAfter - totalReceivedBefore, rewardAmount, "recordBalance should be called with correct amount"
        );
    }

    function test_Rebalance_EmitsRewardsDeltaEvent() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        vm.expectEmit(true, true, true, true, address(core));
        emit RewardsDelta(rewardAmount);

        vm.prank(operator);
        core.rebalance();
    }

    function test_Rebalance_EmitsRewardsDeltaEvent_WithZeroRewards() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setHarvestedRewards(0);

        vm.expectEmit(true, true, true, true, address(core));
        emit RewardsDelta(0);

        vm.prank(operator);
        core.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_TotalAssetsComposition(
        uint96 buffered,
        uint96 staked,
        uint96 rewardsAccumulatorBalance,
        uint96 claimableRewards,
        uint96 slashingDeltaSeed
    ) external {
        buffered = uint96(bound(buffered, 1, type(uint96).max));
        staked = uint96(bound(staked, 1, type(uint96).max));
        rewardsAccumulatorBalance = uint96(bound(rewardsAccumulatorBalance, 1, type(uint96).max));
        claimableRewards = uint96(bound(claimableRewards, 0, type(uint96).max));

        uint256 positiveTotal =
            uint256(buffered) + uint256(staked) + uint256(rewardsAccumulatorBalance) + uint256(claimableRewards);
        uint256 slashingDelta = bound(uint256(slashingDeltaSeed), 0, positiveTotal);

        // Drive each composition term through its live source so the pull-model totalAssets() reads
        // the intended value at call time: vault owns buffered, stakingManager owns staked +
        // claimable + slashingDelta, and the accumulator contract owns rewardsAccumulatorBalance.
        asset.mint(address(vault), buffered);
        vm.prank(governance);
        vault.reconcileBufferedAssets();
        stakingManager.setTotalStaked(staked);
        stakingManager.setClaimableRewards(claimableRewards);
        // setSlashingDelta subtracts the increment from totalStakedAmount; restore staked after.
        stakingManager.setSlashingDelta(slashingDelta);
        stakingManager.setTotalStaked(staked);
        deal(address(asset), address(rewardsAccumulator), rewardsAccumulatorBalance);

        // totalAssets() is net-of-slashing via stakingManager.totalStaked(); slashingDelta is
        // informational in the accountingState() view only.
        assertEq(
            core.totalAssets(), positiveTotal, "totalAssets equals positive total (slashingDelta is informational)"
        );
    }

    function testFuzz_ComputeNetFlows(
        uint96 cumulativeDeposits,
        uint96 cumulativeWithdrawals,
        uint96 latestReportCumulativeDeposits,
        uint96 latestReportCumulativeWithdrawals
    ) external view {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: cumulativeDeposits,
            cumulativeWithdrawals: cumulativeWithdrawals,
            cumulativeSlashingAdjustments: 0,
            latestReportCumulativeDeposits: latestReportCumulativeDeposits,
            latestReportCumulativeWithdrawals: latestReportCumulativeWithdrawals,
            latestReportCumulativeSlashingAdjustments: 0
        });

        (int256 netFlows, uint256 netDeposits, int256 netWithdrawals) = core.exposedComputeNetFlows(flows);

        uint256 expectedNetDeposits =
            cumulativeDeposits > latestReportCumulativeDeposits
            ? cumulativeDeposits - latestReportCumulativeDeposits
            : 0;
        uint256 expectedRawNetWithdrawals = cumulativeWithdrawals > latestReportCumulativeWithdrawals
            ? cumulativeWithdrawals - latestReportCumulativeWithdrawals
            : 0;
        int256 expectedNetWithdrawals = int256(expectedRawNetWithdrawals);
        int256 expectedNetFlows = int256(expectedNetDeposits) - expectedNetWithdrawals;

        assertEq(netDeposits, expectedNetDeposits, "net deposits fuzz");
        assertEq(netWithdrawals, expectedNetWithdrawals, "net withdrawals fuzz");
        assertEq(netFlows, expectedNetFlows, "net flows fuzz");
    }

    /// @notice Fuzz _computeNetFlows with slashing adjustments included.
    function testFuzz_ComputeNetFlows_WithSlashingAdjustments(
        uint96 cumulativeDeposits,
        uint96 cumulativeWithdrawals,
        uint96 cumulativeSlashingAdj,
        uint96 latestReportCumulativeDeposits,
        uint96 latestReportCumulativeWithdrawals,
        uint96 latestReportCumulativeSlashingAdj
    ) external view {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: cumulativeDeposits,
            cumulativeWithdrawals: cumulativeWithdrawals,
            cumulativeSlashingAdjustments: cumulativeSlashingAdj,
            latestReportCumulativeDeposits: latestReportCumulativeDeposits,
            latestReportCumulativeWithdrawals: latestReportCumulativeWithdrawals,
            latestReportCumulativeSlashingAdjustments: latestReportCumulativeSlashingAdj
        });

        (int256 netFlows, uint256 netDeposits, int256 netWithdrawals) = core.exposedComputeNetFlows(flows);

        uint256 expectedNetDeposits =
            cumulativeDeposits > latestReportCumulativeDeposits
            ? cumulativeDeposits - latestReportCumulativeDeposits
            : 0;
        uint256 rawNetWithdrawals = cumulativeWithdrawals > latestReportCumulativeWithdrawals
            ? cumulativeWithdrawals - latestReportCumulativeWithdrawals
            : 0;
        uint256 adjustmentDelta = cumulativeSlashingAdj > latestReportCumulativeSlashingAdj
            ? cumulativeSlashingAdj - latestReportCumulativeSlashingAdj
            : 0;
        // Signed: excess slashing adjustment becomes negative netWithdrawals (no clamp).
        int256 expectedNetWithdrawals = int256(rawNetWithdrawals) - int256(adjustmentDelta);
        int256 expectedNetFlows = int256(expectedNetDeposits) - expectedNetWithdrawals;

        assertEq(netDeposits, expectedNetDeposits, "net deposits fuzz with adj");
        assertEq(netWithdrawals, expectedNetWithdrawals, "net withdrawals fuzz with adj");
        assertEq(netFlows, expectedNetFlows, "net flows fuzz with adj");
    }

    function testFuzz_ComputeGrossRewards(uint96 oldTotalAssets, uint96 newTotalAssets, int96 netFlows) external view {
        (uint256 grossRewards, int256 grossRewardsSigned) =
            core.exposedComputeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        int256 changeInAssets = int256(uint256(newTotalAssets)) - int256(uint256(oldTotalAssets));
        int256 expectedGrossSigned = changeInAssets - int256(netFlows);
        uint256 expectedGross = expectedGrossSigned > 0 ? uint256(expectedGrossSigned) : 0;

        assertEq(grossRewards, expectedGross, "gross rewards fuzz");
        assertEq(grossRewardsSigned, expectedGrossSigned, "gross rewards signed fuzz");
    }

    /*//////////////////////////////////////////////////////////////
               FUZZ: SHARE/ASSET CONVERSION ROUNDTRIP
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ShareAssetConversionRoundtrip(uint96 depositSeed, uint96 rewardsSeed, uint96 assetsSeed)
        external
    {
        uint256 depositAmount = bound(uint256(depositSeed), 1e18, type(uint96).max);
        uint256 rewards = bound(uint256(rewardsSeed), 1, type(uint96).max / 2);

        // Deposit to establish supply
        _performDeposit(alice, depositAmount);

        // Add rewards to create a non-trivial exchange rate
        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        // Fuzz the asset amount to convert
        uint256 assets = bound(uint256(assetsSeed), 1, type(uint96).max);

        // Roundtrip: assets -> shares -> assets
        uint256 shares = core.convertToShares(assets);
        uint256 assetsBack = core.convertToAssets(shares);

        // Each floor-division step loses at most (totalAssets+1)/(totalSupply+1) wei.
        // With two steps the max loss is proportional to the exchange rate.
        uint256 rate = core.exchangeRate();
        uint256 maxRoundingLoss = 2 * rate / 1e18 + 2;
        assertLe(assets - assetsBack, maxRoundingLoss, "roundtrip rounding loss proportional to rate");
    }

    /*//////////////////////////////////////////////////////////////
                   CONVERT TO ASSETS CEIL
    //////////////////////////////////////////////////////////////*/

    function test_ConvertToAssetsCeil_RoundsUp() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Add rewards to create a non-trivial exchange rate (totalAssets > totalSupply)
        stakingManager.setClaimableRewards(50 * DECIMALS);
        vm.prank(operator);
        core.updateAccounting();

        // Pick a share amount that triggers a non-integer result
        uint256 shares = 1;
        uint256 assetsFloor = core.convertToAssets(shares);
        uint256 assetsCeil = core.convertToAssetsCeil(shares);

        assertGe(assetsCeil, assetsFloor, "ceil >= floor");
    }

    function test_ConvertToAssetsCeil_MatchesFloor_WhenExact() external {
        // 1:1 rate -- both rounding modes yield the same result
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 shares = 10 * DECIMALS;
        uint256 assetsFloor = core.convertToAssets(shares);
        uint256 assetsCeil = core.convertToAssetsCeil(shares);

        assertEq(assetsCeil, assetsFloor, "ceil == floor when division is exact");
    }

    function test_ConvertToAssetsCeil_ZeroShares() external {
        _performDeposit(alice, 100 * DECIMALS);

        assertEq(core.convertToAssetsCeil(0), 0, "zero shares -> zero assets");
        assertEq(core.convertToAssets(0), 0, "zero shares -> zero assets (floor)");
    }

    function testFuzz_ConvertToAssetsCeil_AlwaysGteFloor(uint96 depositSeed, uint96 rewardsSeed, uint96 sharesSeed)
        external
    {
        uint256 depositAmount = bound(uint256(depositSeed), 1e18, type(uint96).max);
        uint256 rewards = bound(uint256(rewardsSeed), 1, type(uint96).max / 2);

        _performDeposit(alice, depositAmount);

        stakingManager.setClaimableRewards(rewards);
        vm.prank(operator);
        core.updateAccounting();

        uint256 shares = bound(uint256(sharesSeed), 0, type(uint96).max);

        uint256 assetsFloor = core.convertToAssets(shares);
        uint256 assetsCeil = core.convertToAssetsCeil(shares);

        assertGe(assetsCeil, assetsFloor, "ceil must always be >= floor");
        assertLe(assetsCeil - assetsFloor, 1, "ceil and floor differ by at most 1 wei");
    }

    /*//////////////////////////////////////////////////////////////
                        SLASHING DELTA UNDERFLOW
    //////////////////////////////////////////////////////////////*/

    function test_TotalAssets_ClampsToZero_WhenAllStakedAssetsSlashed() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Move all to staked so buffer is empty
        stakingManager.setStakeReturnAmount(depositAmount);
        vm.prank(operator);
        core.rebalance();

        // Slash all staked assets
        stakingManager.setTotalStaked(depositAmount);
        stakingManager.setSlashingDelta(depositAmount); // totalStaked → 0

        vm.prank(operator);
        core.updateAccounting();

        // totalAssets should be zero because buffer=0 and totalStaked=0
        assertEq(core.totalAssets(), 0, "totalAssets should clamp to zero when all staked assets slashed");
    }

    function test_TotalAssets_BufferedAssetsSurviveSlashing() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // All assets in buffer, nothing staked -- slashing doesn't affect buffered assets
        stakingManager.setTotalStaked(0);
        stakingManager.setSlashingDelta(5 * DECIMALS);

        vm.prank(operator);
        core.updateAccounting();

        // Buffered assets are NOT reduced by slashingDelta
        assertEq(core.totalAssets(), depositAmount, "buffered assets survive slashing");
    }

    function test_ComputeTotalAssets_ClampsToZero_WhenPendingWithdrawalsExceedsSum() external view {
        IOllaCore.AccountingState memory buckets = IOllaCore.AccountingState({
            stakedPrincipal: 4 * DECIMALS,
            rewardsAccumulatorBalance: 2 * DECIMALS,
            claimableRewards: 1 * DECIMALS,
            rewardsDelta: 0,
            slashingDelta: 0,
            cumulativeRewards: 0
        });

        // pendingWithdrawals (20e18) > total (10e18), so result should clamp to 0
        uint256 result = core.exposedComputeTotalAssets(buckets, 3 * DECIMALS, 20 * DECIMALS);

        assertEq(result, 0, "computeTotalAssets should return zero when pendingWithdrawals exceeds sum");
    }

    function test_DepositStillWorks_AfterSlashingClampsToZero() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Move all to staked so buffer is empty
        stakingManager.setStakeReturnAmount(depositAmount);
        vm.prank(operator);
        core.rebalance();

        // Slash all staked assets → totalAssets = 0
        stakingManager.setTotalStaked(depositAmount);
        stakingManager.setSlashingDelta(depositAmount); // totalStaked → 0

        vm.prank(operator);
        core.updateAccounting();

        assertEq(core.totalAssets(), 0, "totalAssets should be zero after massive slashing");

        // A subsequent deposit should succeed without reverting
        address bob = makeAddr("bob");
        uint256 secondDeposit = 5 * DECIMALS;
        asset.mint(bob, secondDeposit);
        vm.prank(bob);
        asset.approve(address(vault), secondDeposit);
        vm.prank(bob);
        vault.deposit(secondDeposit, bob, 0);

        // After deposit, totalAssets = new buffer (secondDeposit), since staked is still 0
        assertEq(core.totalAssets(), secondDeposit, "totalAssets should reflect new deposit in buffer");
    }

    function testFuzz_TotalAssets_NeverRevertsWithPendingWithdrawals(
        uint96 buffered,
        uint96 staked,
        uint96 rvBalance,
        uint96 claimable,
        uint96 pendingWithdrawalsSeed
    ) external view {
        buffered = uint96(bound(buffered, 0, type(uint96).max));
        staked = uint96(bound(staked, 0, type(uint96).max));
        rvBalance = uint96(bound(rvBalance, 0, type(uint96).max));
        claimable = uint96(bound(claimable, 0, type(uint96).max));

        uint256 positiveTotal = uint256(buffered) + uint256(staked) + uint256(rvBalance) + uint256(claimable);

        // Allow pending withdrawals to exceed the positive total
        uint256 pending = bound(uint256(pendingWithdrawalsSeed), 0, positiveTotal + 100 * DECIMALS);

        IOllaCore.AccountingState memory buckets = IOllaCore.AccountingState({
            stakedPrincipal: staked,
            rewardsAccumulatorBalance: rvBalance,
            claimableRewards: claimable,
            rewardsDelta: 0,
            slashingDelta: 0,
            cumulativeRewards: 0
        });

        uint256 result = core.exposedComputeTotalAssets(buckets, buffered, pending);

        // Result should be clamped: zero when pendingWithdrawals >= sum, otherwise sum - pending
        if (pending >= positiveTotal) {
            assertEq(result, 0, "should clamp to zero when pending >= sum");
        } else {
            assertEq(result, positiveTotal - pending, "should return sum minus pending withdrawals");
        }
    }

    /*//////////////////////////////////////////////////////////////
              MOCK setSlashingDelta COUPLING WITH totalStaked
    //////////////////////////////////////////////////////////////*/

    /// @notice setSlashingDelta reduces totalStaked by the incremental increase.
    function test_MockSetSlashingDelta_ReducesTotalStaked() external {
        stakingManager.setTotalStaked(100 * DECIMALS);
        assertEq(stakingManager.totalStaked(), 100 * DECIMALS);

        stakingManager.setSlashingDelta(30 * DECIMALS);

        assertEq(stakingManager.totalStaked(), 70 * DECIMALS, "totalStaked should decrease by slashingDelta");
        assertEq(stakingManager.slashingDelta(), 30 * DECIMALS, "slashingDelta stored correctly");
    }

    /// @notice Incremental setSlashingDelta calls only reduce by the increment.
    function test_MockSetSlashingDelta_IncrementalReduction() external {
        stakingManager.setTotalStaked(100 * DECIMALS);

        stakingManager.setSlashingDelta(10 * DECIMALS);
        assertEq(stakingManager.totalStaked(), 90 * DECIMALS, "first slash: 100 - 10 = 90");

        stakingManager.setSlashingDelta(25 * DECIMALS);
        assertEq(stakingManager.totalStaked(), 75 * DECIMALS, "second slash: 90 - 15 = 75");

        // Setting same value again should not reduce further
        stakingManager.setSlashingDelta(25 * DECIMALS);
        assertEq(stakingManager.totalStaked(), 75 * DECIMALS, "no-op when slashingDelta unchanged");
    }

    /// @notice setSlashingDelta saturates totalStaked to 0 when slash exceeds staked.
    function test_MockSetSlashingDelta_SaturatesToZero() external {
        stakingManager.setTotalStaked(10 * DECIMALS);

        stakingManager.setSlashingDelta(50 * DECIMALS);

        assertEq(stakingManager.totalStaked(), 0, "totalStaked should saturate to 0");
        assertEq(stakingManager.slashingDelta(), 50 * DECIMALS, "slashingDelta stored even when exceeding staked");
    }

    /// @notice setTotalStaked after setSlashingDelta overrides the reduced value.
    function test_MockSetTotalStaked_OverridesSlashingReduction() external {
        stakingManager.setTotalStaked(100 * DECIMALS);
        stakingManager.setSlashingDelta(30 * DECIMALS);
        assertEq(stakingManager.totalStaked(), 70 * DECIMALS);

        // setTotalStaked directly overrides -- caller is responsible for consistency
        stakingManager.setTotalStaked(200 * DECIMALS);
        assertEq(stakingManager.totalStaked(), 200 * DECIMALS, "setTotalStaked should override");
    }
}
