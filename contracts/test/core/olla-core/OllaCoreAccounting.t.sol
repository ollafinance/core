// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";

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
    event AttestersStateRead(uint256 rewardsDelta, uint256 slashingDelta, uint256 timestamp);
    event Rebalanced(
        uint256 bufferedAssets, uint256 stakedPrincipal, uint256 rewardsVaultBalance, uint256 rewardsDelta
    );
    event RewardsDelta(uint256 delta);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal operator;
    address internal providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreHarness(address(proxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        operator = makeAddr("operator");
        withdrawalQueue = new MockWithdrawalQueue();
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

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
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();
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
        uint256 rewardsVaultBalance = 4 * DECIMALS;
        uint256 claimableRewards = 3 * DECIMALS;
        uint256 rewardsDelta = 2 * DECIMALS;
        uint256 slashingDelta = 1 * DECIMALS;

        _performDeposit(alice, assets);
        vault.exposedApplyAccountingUpdates(staked, rewardsVaultBalance, claimableRewards, rewardsDelta, slashingDelta);

        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertEq(accounting.bufferedAssets, assets, "bufferedAssets matches deposited assets");
        assertEq(accounting.stakedPrincipal, staked, "stakedPrincipal matches staked amount");
        assertEq(accounting.rewardsVaultBalance, rewardsVaultBalance, "rewardsVaultBalance matches rewards vault");
        assertEq(accounting.claimableRewards, claimableRewards, "claimableRewards matches claimable rewards");
        assertEq(accounting.rewardsDelta, rewardsDelta, "rewardsDelta matches rewards delta");
        assertEq(accounting.slashingDelta, slashingDelta, "slashingDelta matches slashing delta");
        assertEq(
            vault.totalAssets(),
            assets + staked + rewardsVaultBalance + claimableRewards - slashingDelta,
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

        (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals) = vault.exposedComputeNetFlows(flows);

        assertEq(netDeposits, 7 * DECIMALS, "net deposits");
        assertEq(netWithdrawals, 3 * DECIMALS, "net withdrawals");
        assertEq(netFlows, int256(4 * DECIMALS), "net flows");
    }

    function test_ComputeTotalAssets() external view {
        IOllaCore.AccountingState memory buckets = IOllaCore.AccountingState({
            bufferedAssets: 3 * DECIMALS,
            stakedPrincipal: 4 * DECIMALS,
            rewardsVaultBalance: 2 * DECIMALS,
            claimableRewards: 5 * DECIMALS,
            rewardsDelta: 1 * DECIMALS,
            slashingDelta: 5 * DECIMALS,
            cumulativeRewards: 0
        });

        uint256 totalAssets = vault.exposedComputeTotalAssets(buckets);

        assertEq(totalAssets, 9 * DECIMALS, "total assets computed");
    }

    function test_ComputeGrossRewards() external view {
        uint256 grossRewards = vault.exposedComputeGrossRewards(100 * DECIMALS, 130 * DECIMALS, int256(20 * DECIMALS));

        assertEq(grossRewards, 10 * DECIMALS, "gross rewards computed");
    }

    /*//////////////////////////////////////////////////////////////
                          ACCOUNTING UPDATES
    //////////////////////////////////////////////////////////////*/

    function test_UpdateAccountingSnapshots() external {
        uint256 depositAmount = 25 * DECIMALS;

        _performDeposit(alice, depositAmount);

        IOllaCore.LatestReport memory reportBefore = vault.latestReport();
        IOllaCore.FlowCounters memory flowsBefore = vault.flowCounters();
        assertEq(reportBefore.totalAssets, 0, "lastTotalAssets before update");
        assertEq(flowsBefore.latestReportCumulativeDeposits, 0, "latestReportCumulativeDeposits before update");
        assertEq(flowsBefore.latestReportCumulativeWithdrawals, 0, "latestReportCumulativeWithdrawals before update");

        uint256 expectedRate = vault.exchangeRate();
        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(0, 0, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AccountingUpdated(depositAmount, expectedRate, 0, int256(depositAmount), 0, 0, 0, expectedTimestamp);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        IOllaCore.FlowCounters memory flowsAfter = vault.flowCounters();
        assertEq(reportAfter.totalAssets, depositAmount, "lastTotalAssets updated");
        assertEq(reportAfter.exchangeRate, expectedRate, "stored exchange rate updated");
        assertEq(flowsAfter.latestReportCumulativeDeposits, depositAmount, "latestReportCumulativeDeposits updated");
        assertEq(flowsAfter.latestReportCumulativeWithdrawals, 0, "latestReportCumulativeWithdrawals updated");
        assertEq(flowsAfter.cumulativeDeposits, depositAmount, "cumulative deposits tracked");
        assertEq(reportAfter.exchangeRate, expectedRate, "latest report exchange rate stored");
        assertEq(reportAfter.timestamp, expectedTimestamp, "report timestamp updated");
    }

    function test_UpdateAccounting_NetFlowsNegative_ComputesGrossRewards() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        vault.updateAccounting();

        uint256 sharesToRedeem = 40 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 assetsExpected = sharesToRedeem * rate / DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, alice);

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        assertEq(reportAfter.netFlows, -int256(assetsExpected), "net flows negative");
        assertEq(reportAfter.grossRewards, assetsExpected, "gross rewards uses signed net flows");
        assertEq(reportAfter.totalAssets, depositAmount, "total assets unchanged");
    }

    function test_UpdateAccounting_GrossRewardsZero_TotalAssetsZero_NoFeeMinting() external {
        uint256 depositAmount = 12 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        vault.setProtocolFeeBP(1_000);

        stakingManager.setSlashingDelta(depositAmount);

        uint256 supplyBefore = stAztec.totalSupply();
        uint256 treasuryBalanceBefore = stAztec.balanceOf(governance);
        uint256 providerBalanceBefore = stAztec.balanceOf(providerRewardsRecipient);

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
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
        vault.updateAccounting();
        IOllaCore.LatestReport memory firstReport = vault.latestReport();
        uint256 firstTimestamp = firstReport.timestamp;

        vm.warp(firstTimestamp + 1);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory secondReport = vault.latestReport();
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
        vault.rebalance();
        stakingManager.setClaimableRewards(claimableRewards);
        stakingManager.setSlashingDelta(slashing);

        IOllaCore.AccountingState memory accountingAfterRebalance = vault.accountingState();
        IOllaCore.LatestReport memory reportBefore = vault.latestReport();
        IOllaCore.FlowCounters memory flowsBefore = vault.flowCounters();
        uint256 rvBalance = rewardsVault.balance();
        uint256 currentRewards = accountingAfterRebalance.cumulativeRewards + claimableRewards;
        uint256 rDelta =
            currentRewards > reportBefore.rewardsSnapshot ? currentRewards - reportBefore.rewardsSnapshot : 0;
        uint256 expectedTotalAssets =
            accountingAfterRebalance.bufferedAssets + stakedPrincipal + rvBalance + claimableRewards - slashing;
        uint256 expectedRate = expectedTotalAssets.mulDiv(DECIMALS, stAztec.totalSupply(), Math.Rounding.Floor);
        (int256 expectedNetFlows,,) = vault.exposedComputeNetFlows(flowsBefore);
        uint256 expectedGrossRewards =
            vault.exposedComputeGrossRewards(reportBefore.totalAssets, expectedTotalAssets, expectedNetFlows);

        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(rDelta, slashing, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AccountingUpdated(
            expectedTotalAssets, expectedRate, expectedGrossRewards, expectedNetFlows, 0, 0, 0, expectedTimestamp
        );
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        IOllaCore.FlowCounters memory flowsAfter = vault.flowCounters();
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
        vault.rebalance();
        stakingManager.setClaimableRewards(4 * DECIMALS);

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory firstReport = vault.latestReport();
        assertEq(firstReport.rewardsSnapshot, 7 * DECIMALS, "first rewards snapshot stored");

        stakingManager.setHarvestedRewards(2 * DECIMALS);
        vm.prank(operator);
        vault.rebalance();
        stakingManager.setClaimableRewards(9 * DECIMALS);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        IOllaCore.LatestReport memory reportBefore = vault.latestReport();
        uint256 currentRewards = accountingBefore.cumulativeRewards + 9 * DECIMALS;
        uint256 expectedDelta =
            currentRewards > reportBefore.rewardsSnapshot ? currentRewards - reportBefore.rewardsSnapshot : 0;
        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(expectedDelta, 0, expectedTimestamp);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory secondReport = vault.latestReport();
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertEq(accounting.rewardsDelta, expectedDelta, "rewards delta stored");
        assertEq(secondReport.rewardsSnapshot, 14 * DECIMALS, "rewards snapshot advanced");
    }

    function test_UpdateAccounting_RewardsDeltaClampsWhenClaimableDecreases() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setClaimableRewards(10 * DECIMALS);
        vm.prank(operator);
        vault.updateAccounting();

        stakingManager.setClaimableRewards(5 * DECIMALS);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertEq(accounting.rewardsDelta, 0, "rewards delta clamps to zero");
        assertEq(reportAfter.rewardsSnapshot, 5 * DECIMALS, "rewards snapshot tracks current rewards");
    }

    function test_UpdateAccounting_ClaimableRewardsPersistWithoutHarvest() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 claimableRewards = 5 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setClaimableRewards(claimableRewards);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.AccountingState memory accountingAfterFirst = vault.accountingState();
        assertEq(accountingAfterFirst.claimableRewards, claimableRewards, "claimable rewards stored");
        assertEq(vault.totalAssets(), depositAmount + claimableRewards, "total assets include claimable rewards");

        stakingManager.setClaimableRewards(claimableRewards);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.AccountingState memory accountingAfterSecond = vault.accountingState();
        IOllaCore.LatestReport memory reportAfterSecond = vault.latestReport();
        assertEq(accountingAfterSecond.claimableRewards, claimableRewards, "claimable rewards persist");
        assertEq(accountingAfterSecond.rewardsDelta, 0, "rewards delta resets to zero");
        assertEq(reportAfterSecond.rewardsSnapshot, claimableRewards, "rewards snapshot unchanged");
        assertEq(vault.totalAssets(), depositAmount + claimableRewards, "total assets remain stable");
    }

    function test_RevertWhen_UpdateAccountingSlashingDeltaDecreases() external {
        _performDeposit(alice, 5 * DECIMALS);

        stakingManager.setSlashingDelta(2 * DECIMALS);
        vm.prank(operator);
        vault.updateAccounting();

        stakingManager.setSlashingDelta(1 * DECIMALS);
        vm.expectRevert(
            abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSlashingDelta.selector, 2 * DECIMALS, 1 * DECIMALS)
        );
        vm.prank(operator);
        vault.updateAccounting();
    }

    function test_UpdateAccounting_InvokesSafetyChecks() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 sharesToRedeem = 5 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 assetsExpected = sharesToRedeem * rate / DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, alice);

        uint256 oldRate = 1e18;
        uint256 expectedRate = vault.exchangeRate();
        uint256 expectedTotalAssets = vault.totalAssets();
        vm.expectCall(address(safetyModule), abi.encodeCall(ISafetyModule.checkAccountingLiveness, ()));
        vm.expectCall(
            address(safetyModule), abi.encodeCall(ISafetyModule.checkQueueRatio, (assetsExpected, expectedTotalAssets))
        );
        vm.expectCall(address(safetyModule), abi.encodeCall(ISafetyModule.checkRateDrop, (oldRate, expectedRate)));
        vm.expectCall(
            address(safetyModule), abi.encodeCall(ISafetyModule.setLatestAccountingTimestamp, (block.timestamp))
        );

        vm.prank(operator);
        vault.updateAccounting();
    }

    /*//////////////////////////////////////////////////////////////
                          REBALANCE HARVEST
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_CallsRecordRewardsWithCorrectAmount() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        uint256 totalReceivedBefore = rewardsVault.totalReceived();

        vm.prank(operator);
        vault.rebalance();

        uint256 totalReceivedAfter = rewardsVault.totalReceived();
        assertEq(
            totalReceivedAfter - totalReceivedBefore, rewardAmount, "recordBalance should be called with correct amount"
        );
    }

    function test_Rebalance_EmitsRewardsDeltaEvent() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsDelta(rewardAmount);

        vm.prank(operator);
        vault.rebalance();
    }

    function test_Rebalance_EmitsRewardsDeltaEvent_WithZeroRewards() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setHarvestedRewards(0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsDelta(0);

        vm.prank(operator);
        vault.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_TotalAssetsComposition(
        uint96 buffered,
        uint96 staked,
        uint96 rewardsVaultBalance,
        uint96 claimableRewards,
        uint96 rewardsDelta,
        uint96 slashingDeltaSeed
    ) external {
        buffered = uint96(bound(buffered, 1, type(uint96).max));
        staked = uint96(bound(staked, 1, type(uint96).max));
        rewardsVaultBalance = uint96(bound(rewardsVaultBalance, 1, type(uint96).max));
        claimableRewards = uint96(bound(claimableRewards, 0, type(uint96).max));
        rewardsDelta = uint96(bound(rewardsDelta, 0, type(uint96).max));

        uint256 positiveTotal =
            uint256(buffered) + uint256(staked) + uint256(rewardsVaultBalance) + uint256(claimableRewards);
        uint256 slashingDelta = bound(uint256(slashingDeltaSeed), 0, positiveTotal);

        asset.mint(address(vault), buffered);
        vault.exposedIncreaseBuffered(buffered);
        vault.exposedApplyAccountingUpdates(staked, rewardsVaultBalance, claimableRewards, rewardsDelta, slashingDelta);

        assertEq(vault.totalAssets(), positiveTotal - slashingDelta, "totalAssets includes slashing delta");
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

        (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals) = vault.exposedComputeNetFlows(flows);

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
        uint256 grossRewards = vault.exposedComputeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        int256 changeInAssets = int256(uint256(newTotalAssets)) - int256(uint256(oldTotalAssets));
        int256 expectedGrossSigned = changeInAssets - int256(netFlows);
        uint256 expectedGross = expectedGrossSigned > 0 ? uint256(expectedGrossSigned) : 0;

        assertEq(grossRewards, expectedGross, "gross rewards fuzz");
    }

    /*//////////////////////////////////////////////////////////////
                    ATTESTER STATE STALENESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UpdateAccounting_AttesterStateStale() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setSlashingDelta(1 * DECIMALS);
        (uint256 lastUpdated,,) = stakingManager.getAttesterStateLiveness();

        uint256 maxAge = 1 hours;
        stakingManager.setAttesterStateMaxAge(maxAge);

        vm.warp(lastUpdated + maxAge + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__AttesterStateStale.selector, lastUpdated, maxAge)
        );
        vm.prank(operator);
        vault.updateAccounting();
    }

    function test_UpdateAccounting_SucceedsAtExactStalenessThreshold() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setSlashingDelta(1 * DECIMALS);
        (uint256 lastUpdated,,) = stakingManager.getAttesterStateLiveness();

        uint256 maxAge = 1 hours;
        stakingManager.setAttesterStateMaxAge(maxAge);

        vm.warp(lastUpdated + maxAge);

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory report = vault.latestReport();
        assertGt(report.timestamp, 0, "accounting should have been updated");
    }

    function test_RevertWhen_UpdateAccounting_TotalStakedStale() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setTotalStaked(5 * DECIMALS);
        (uint256 lastUpdated,,) = stakingManager.getAttesterStateLiveness();

        uint256 maxAge = 1 hours;
        stakingManager.setAttesterStateMaxAge(maxAge);

        vm.warp(lastUpdated + maxAge + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__AttesterStateStale.selector, lastUpdated, maxAge)
        );
        vm.prank(operator);
        vault.updateAccounting();
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
        vault.updateAccounting();

        // Fuzz the asset amount to convert
        uint256 assets = bound(uint256(assetsSeed), 1, type(uint96).max);

        // Roundtrip: assets → shares → assets
        uint256 shares = vault.convertToShares(assets);
        uint256 assetsBack = vault.convertToAssets(shares);

        // Each floor-division step loses at most (totalAssets+1)/(totalSupply+1) wei.
        // With two steps the max loss is proportional to the exchange rate.
        uint256 rate = vault.exchangeRate();
        uint256 maxRoundingLoss = 2 * rate / 1e18 + 2;
        assertLe(assets - assetsBack, maxRoundingLoss, "roundtrip rounding loss proportional to rate");
    }
}
