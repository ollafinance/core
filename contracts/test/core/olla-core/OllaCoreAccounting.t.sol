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
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
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
    MockWithdrawalQueue internal withdrawalQueue;
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
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        operator = makeAddr("operator");
        withdrawalQueue = new MockWithdrawalQueue();
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

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

        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.startPrank(governance);
        core.grantRole(operatorRole, operator);
        core.grantRole(operatorRole, address(this));
        vm.stopPrank();

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
        uint256 rewardsDelta = 2 * DECIMALS;
        uint256 slashingDelta = 1 * DECIMALS;

        _performDeposit(alice, assets);
        core.exposedApplyAccountingUpdates(
            staked, rewardsAccumulatorBalance, claimableRewards, rewardsDelta, slashingDelta
        );

        IOllaCore.AccountingState memory accounting = core.accountingState();
        assertEq(vault.bufferedAssets(), assets, "bufferedAssets matches deposited assets");
        assertEq(accounting.stakedPrincipal, staked, "stakedPrincipal matches staked amount");
        assertEq(
            accounting.rewardsAccumulatorBalance,
            rewardsAccumulatorBalance,
            "rewardsAccumulatorBalance matches rewards vault"
        );
        assertEq(accounting.claimableRewards, claimableRewards, "claimableRewards matches claimable rewards");
        assertEq(accounting.rewardsDelta, rewardsDelta, "rewardsDelta matches rewards delta");
        assertEq(accounting.slashingDelta, slashingDelta, "slashingDelta matches slashing delta");
        assertEq(
            core.totalAssets(),
            assets + staked + rewardsAccumulatorBalance + claimableRewards - slashingDelta,
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
            latestReportCumulativeDeposits: 5 * DECIMALS,
            latestReportCumulativeWithdrawals: 1 * DECIMALS
        });

        (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals) = core.exposedComputeNetFlows(flows);

        assertEq(netDeposits, 7 * DECIMALS, "net deposits");
        assertEq(netWithdrawals, 3 * DECIMALS, "net withdrawals");
        assertEq(netFlows, int256(4 * DECIMALS), "net flows");
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

        assertEq(totalAssets, 9 * DECIMALS, "total assets computed");
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
        // No actual rewards accrued — pending withdrawal assets are excluded from totalAssets
        // so the formula correctly computes grossRewards = 0 instead of phantom rewards.
        assertEq(reportAfter.grossRewards, 0, "no phantom rewards from withdrawal requests");
        assertEq(reportAfter.totalAssets, depositAmount - assetsExpected, "total assets excludes pending withdrawals");
    }

    function test_UpdateAccounting_GrossRewardsZero_TotalAssetsZero_NoFeeMinting() external {
        uint256 depositAmount = 12 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        core.setProtocolFeeBP(1_000);

        stakingManager.setSlashingDelta(depositAmount);

        uint256 supplyBefore = stAztec.totalSupply();
        uint256 treasuryBalanceBefore = stAztec.balanceOf(governance);
        uint256 providerBalanceBefore = stAztec.balanceOf(providerRewardsRecipient);

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        assertEq(reportAfter.grossRewards, 0, "gross rewards zero");
        assertEq(reportAfter.totalAssets, 0, "total assets zero");
        assertEq(reportAfter.exchangeRate, 0, "exchange rate zero");
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

    function test_UpdateAccountingIncludesRewardsAndSlashing() external {
        uint256 depositAmount = 20 * DECIMALS;
        uint256 harvestedRewards = 5 * DECIMALS;
        uint256 claimableRewards = 7 * DECIMALS;
        uint256 slashing = 2 * DECIMALS;
        uint256 stakedPrincipal = 11 * DECIMALS;

        _performDeposit(alice, depositAmount);
        stakingManager.setTotalStaked(stakedPrincipal);
        stakingManager.setHarvestedRewards(harvestedRewards);
        vm.prank(operator);
        core.rebalance();
        stakingManager.setClaimableRewards(claimableRewards);
        stakingManager.setSlashingDelta(slashing);

        IOllaCore.AccountingState memory accountingAfterRebalance = core.accountingState();
        IOllaCore.LatestReport memory reportBefore = core.latestReport();
        IOllaCore.FlowCounters memory flowsBefore = core.flowCounters();
        uint256 rvBalance = rewardsAccumulator.balance();
        uint256 currentRewards = accountingAfterRebalance.cumulativeRewards + claimableRewards;
        uint256 expectedTotalAssets = vault.bufferedAssets() + stakedPrincipal + rvBalance + claimableRewards - slashing;
        uint256 expectedRate = expectedTotalAssets.mulDiv(DECIMALS, stAztec.totalSupply(), Math.Rounding.Floor);
        (int256 expectedNetFlows,,) = core.exposedComputeNetFlows(flowsBefore);
        (uint256 expectedGrossRewards,) =
            core.exposedComputeGrossRewards(reportBefore.totalAssets, expectedTotalAssets, expectedNetFlows);

        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(core));
        emit AccountingUpdated(
            expectedTotalAssets, expectedRate, expectedGrossRewards, expectedNetFlows, 0, 0, 0, expectedTimestamp
        );
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        IOllaCore.FlowCounters memory flowsAfter = core.flowCounters();
        assertEq(reportAfter.totalAssets, expectedTotalAssets, "lastTotalAssets updated");
        assertEq(reportAfter.exchangeRate, expectedRate, "stored exchange rate updated");
        assertEq(reportAfter.rewardsSnapshot, currentRewards, "rewards snapshot updated");
        assertEq(flowsAfter.latestReportCumulativeDeposits, depositAmount, "latestReportCumulativeDeposits updated");
        assertEq(flowsAfter.latestReportCumulativeWithdrawals, 0, "latestReportCumulativeWithdrawals updated");
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

        IOllaCore.AccountingState memory accountingBefore = core.accountingState();
        IOllaCore.LatestReport memory reportBefore = core.latestReport();
        uint256 currentRewards = accountingBefore.cumulativeRewards + 9 * DECIMALS;
        uint256 expectedDelta =
            currentRewards > reportBefore.rewardsSnapshot ? currentRewards - reportBefore.rewardsSnapshot : 0;
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory secondReport = core.latestReport();
        IOllaCore.AccountingState memory accounting = core.accountingState();
        assertEq(accounting.rewardsDelta, expectedDelta, "rewards delta stored");
        assertEq(secondReport.rewardsSnapshot, 14 * DECIMALS, "rewards snapshot advanced");
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

    function test_UpdateAccounting_ClaimableRewardsPersistWithoutHarvest() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 claimableRewards = 5 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setClaimableRewards(claimableRewards);
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.AccountingState memory accountingAfterFirst = core.accountingState();
        assertEq(accountingAfterFirst.claimableRewards, claimableRewards, "claimable rewards stored");
        assertEq(core.totalAssets(), depositAmount + claimableRewards, "total assets include claimable rewards");

        stakingManager.setClaimableRewards(claimableRewards);
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.AccountingState memory accountingAfterSecond = core.accountingState();
        IOllaCore.LatestReport memory reportAfterSecond = core.latestReport();
        assertEq(accountingAfterSecond.claimableRewards, claimableRewards, "claimable rewards persist");
        assertEq(accountingAfterSecond.rewardsDelta, 0, "rewards delta resets to zero");
        assertEq(reportAfterSecond.rewardsSnapshot, claimableRewards, "rewards snapshot unchanged");
        assertEq(core.totalAssets(), depositAmount + claimableRewards, "total assets remain stable");
    }

    function test_RevertWhen_UpdateAccountingSlashingDeltaDecreases() external {
        _performDeposit(alice, 5 * DECIMALS);

        stakingManager.setSlashingDelta(2 * DECIMALS);
        vm.prank(operator);
        core.updateAccounting();

        stakingManager.setSlashingDelta(1 * DECIMALS);
        vm.expectRevert(
            abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSlashingDelta.selector, 2 * DECIMALS, 1 * DECIMALS)
        );
        vm.prank(operator);
        core.updateAccounting();
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
        uint96 rewardsDelta,
        uint96 slashingDeltaSeed
    ) external {
        buffered = uint96(bound(buffered, 1, type(uint96).max));
        staked = uint96(bound(staked, 1, type(uint96).max));
        rewardsAccumulatorBalance = uint96(bound(rewardsAccumulatorBalance, 1, type(uint96).max));
        claimableRewards = uint96(bound(claimableRewards, 0, type(uint96).max));
        rewardsDelta = uint96(bound(rewardsDelta, 0, type(uint96).max));

        uint256 positiveTotal =
            uint256(buffered) + uint256(staked) + uint256(rewardsAccumulatorBalance) + uint256(claimableRewards);
        uint256 slashingDelta = bound(uint256(slashingDeltaSeed), 0, positiveTotal);

        // Mint assets to vault to simulate buffered assets
        asset.mint(address(vault), buffered);
        // Use reconcileBufferedAssets to sync the vault's buffer
        vm.prank(governance);
        vault.reconcileBufferedAssets();
        core.exposedApplyAccountingUpdates(
            staked, rewardsAccumulatorBalance, claimableRewards, rewardsDelta, slashingDelta
        );

        assertEq(core.totalAssets(), positiveTotal - slashingDelta, "totalAssets includes slashing delta");
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
            latestReportCumulativeDeposits: latestReportCumulativeDeposits,
            latestReportCumulativeWithdrawals: latestReportCumulativeWithdrawals
        });

        (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals) = core.exposedComputeNetFlows(flows);

        uint256 expectedNetDeposits = cumulativeDeposits > latestReportCumulativeDeposits
            ? cumulativeDeposits - latestReportCumulativeDeposits
            : 0;
        uint256 expectedNetWithdrawals = cumulativeWithdrawals > latestReportCumulativeWithdrawals
            ? cumulativeWithdrawals - latestReportCumulativeWithdrawals
            : 0;
        int256 expectedNetFlows = int256(expectedNetDeposits) - int256(expectedNetWithdrawals);

        assertEq(netDeposits, expectedNetDeposits, "net deposits fuzz");
        assertEq(netWithdrawals, expectedNetWithdrawals, "net withdrawals fuzz");
        assertEq(netFlows, expectedNetFlows, "net flows fuzz");
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

        // Roundtrip: assets → shares → assets
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
        // 1:1 rate — both rounding modes yield the same result
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

    function test_TotalAssets_ClampsToZero_WhenSlashingDeltaExceedsSum() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Set slashing delta to more than the deposited amount
        uint256 excessiveSlashing = depositAmount + 5 * DECIMALS;
        stakingManager.setSlashingDelta(excessiveSlashing);

        vm.prank(operator);
        core.updateAccounting();

        // totalAssets should clamp to zero rather than reverting with underflow
        assertEq(core.totalAssets(), 0, "totalAssets should clamp to zero when slashing exceeds sum");
    }

    function test_TotalAssets_ClampsToZero_WhenSlashingDeltaEqualsSum() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Set slashing delta exactly equal to the deposit amount
        stakingManager.setSlashingDelta(depositAmount);

        vm.prank(operator);
        core.updateAccounting();

        // totalAssets should clamp to zero when slashing equals the sum
        assertEq(core.totalAssets(), 0, "totalAssets should clamp to zero when slashing equals sum");
    }

    function test_ComputeTotalAssets_ClampsToZero_WhenSlashingDeltaExceedsSum() external view {
        IOllaCore.AccountingState memory buckets = IOllaCore.AccountingState({
            stakedPrincipal: 4 * DECIMALS,
            rewardsAccumulatorBalance: 2 * DECIMALS,
            claimableRewards: 1 * DECIMALS,
            rewardsDelta: 0,
            slashingDelta: 20 * DECIMALS,
            cumulativeRewards: 0
        });

        uint256 result = core.exposedComputeTotalAssets(buckets, 3 * DECIMALS, 0);

        // slashingDelta (20e18) > sum of other buckets (10e18), so result should be 0
        assertEq(result, 0, "computeTotalAssets should return zero when slashing exceeds sum");
    }

    function test_DepositStillWorks_AfterSlashingClampsToZero() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Set massive slashing to force totalAssets to zero
        uint256 massiveSlashing = depositAmount + 100 * DECIMALS;
        stakingManager.setSlashingDelta(massiveSlashing);

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

        // After deposit, totalAssets should still clamp to zero because slashingDelta is still massive
        // (buffered increased by secondDeposit, but slashing still exceeds the total)
        assertEq(core.totalAssets(), 0, "totalAssets should still clamp to zero after deposit when slashing is massive");
    }

    function testFuzz_TotalAssets_NeverRevertsOnSlashing(
        uint96 buffered,
        uint96 staked,
        uint96 rvBalance,
        uint96 claimable,
        uint96 slashingSeed
    ) external view {
        buffered = uint96(bound(buffered, 0, type(uint96).max));
        staked = uint96(bound(staked, 0, type(uint96).max));
        rvBalance = uint96(bound(rvBalance, 0, type(uint96).max));
        claimable = uint96(bound(claimable, 0, type(uint96).max));

        uint256 positiveTotal = uint256(buffered) + uint256(staked) + uint256(rvBalance) + uint256(claimable);

        // Allow slashing to exceed the positive total
        uint256 slashing = bound(uint256(slashingSeed), 0, positiveTotal + 100 * DECIMALS);

        IOllaCore.AccountingState memory buckets = IOllaCore.AccountingState({
            stakedPrincipal: staked,
            rewardsAccumulatorBalance: rvBalance,
            claimableRewards: claimable,
            rewardsDelta: 0,
            slashingDelta: slashing,
            cumulativeRewards: 0
        });

        uint256 result = core.exposedComputeTotalAssets(buckets, buffered, 0);

        // Result should be clamped: zero when slashing >= sum, otherwise sum - slashing
        if (slashing >= positiveTotal) {
            assertEq(result, 0, "should clamp to zero when slashing >= sum");
        } else {
            assertEq(result, positiveTotal - slashing, "should return sum minus slashing");
        }
    }
}
