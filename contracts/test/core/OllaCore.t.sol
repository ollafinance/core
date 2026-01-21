// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/interfaces/IOllaCore.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { IStAztec } from "src/interfaces/IStAztec.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockStakingManager } from "src/mocks/MockStakingManager.sol";
import { MockWithdrawalQueue } from "src/mocks/MockWithdrawalQueue.sol";

contract OllaCoreHarness is OllaCore {
    /*//////////////////////////////////////////////////////////////
                           CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function exposedIncreaseBuffered(uint256 amount) external {
        _increaseBuffered(amount);
    }

    function exposedIncreaseStakedPrincipal(uint256 amount) external {
        _increaseStakedPrincipal(amount);
    }

    function exposedDecreaseStakedPrincipal(uint256 amount) external {
        _decreaseStakedPrincipal(amount);
    }

    function exposedIncreaseRewardsVaultBalance(uint256 amount) external {
        _increaseRewardsVaultBalance(amount);
    }

    function exposedSetRewardsDelta(uint256 newValue) external {
        _setRewardsDelta(newValue);
    }

    function exposedSetSlashingDelta(uint256 newValue) external {
        _setSlashingDelta(newValue);
    }

    function exposedStake(uint256 amount) external {
        _stake(amount);
    }

    function exposedUnstake(uint256 amount) external {
        _unstake(amount);
    }

    function exposedSyncBufferedWithBalance() external view {
        _syncBufferedWithBalance();
    }

    function exposedComputeNetFlows(IOllaCore.FlowCounters memory flows)
        external
        pure
        returns (uint256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        return _computeNetFlows(flows);
    }

    function exposedComputeTotalAssets(IOllaCore.AccountingState memory buckets)
        external
        pure
        returns (uint256 totalAssets_)
    {
        return _computeTotalAssets(buckets);
    }

    function exposedComputeGrossRewards(uint256 oldTotalAssets, uint256 newTotalAssets, uint256 netFlows)
        external
        pure
        returns (uint256 grossRewards)
    {
        return _computeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
    }
}

contract OllaCoreUpgradeMock is OllaCore {
    /*//////////////////////////////////////////////////////////////
                           CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract OllaCoreTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event Paused();
    event Unpaused();
    event Rebalanced(
        uint256 bufferedAssets, uint256 stakedPrincipal, uint256 rewardsVaultBalance, uint256 rewardsDelta
    );
    event AccountingUpdated(
        uint256 totalAssets,
        uint256 exchangeRate,
        uint256 grossRewards,
        uint256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares,
        uint256 timestamp
    );
    event AttestersStateRead(uint256 rewardsDelta, uint256 slashingDelta, uint256 timestamp);
    event WithdrawalFinalized(uint256 available, uint256 used);
    event Upgraded(address indexed implementation);
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed receiver,
        uint256 shares,
        uint256 assetsExpected,
        uint256 exchangeRate
    );

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
    MockStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal bob;
    MockWithdrawalQueue internal withdrawalQueue;
    address internal rewardsVault;
    address internal safetyModule;
    address internal operator;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreHarness(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        governance = makeAddr("governance");
        rewardsVault = makeAddr("rewardsVault");
        safetyModule = makeAddr("safetyModule");
        operator = makeAddr("operator");
        withdrawalQueue = new MockWithdrawalQueue();

        vault.initialize(
            asset, stAztec, stakingManager, governance, address(withdrawalQueue), rewardsVault, safetyModule
        );

        alice = makeAddr("alice");
        bob = makeAddr("bob");

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
        shares = vault.deposit(assets, owner);
        return shares;
    }

    function _queueRequestSnapshot()
        internal
        view
        returns (address user, uint256 shares, uint256 assetsExpected, uint256 rate)
    {
        (user,,, shares, assetsExpected, rate) = withdrawalQueue.lastRequest();
        return (user, shares, assetsExpected, rate);
    }

    /*//////////////////////////////////////////////////////////////
                          INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_InitializeSetsCoreAddresses() external view {
        assertEq(vault.asset(), address(asset), "asset set");
        assertEq(vault.stAztec(), address(stAztec), "stAztec set");
        assertEq(vault.stakingManager(), address(stakingManager), "staking manager set");
        assertEq(vault.governance(), governance, "governance set");
        assertEq(vault.withdrawalQueue(), address(withdrawalQueue), "withdrawal queue set");
        assertEq(vault.rewardsVault(), rewardsVault, "rewards vault set");
        assertEq(vault.safetyModule(), safetyModule, "safety module set");
        IOllaCore.LatestReport memory report = vault.latestReport();
        assertEq(report.exchangeRate, 1e18, "exchange rate init");
        assertEq(report.totalAssets, 0, "lastTotalAssets init");
    }

    function test_RevertWhen_Reinitialize() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(
            asset, stAztec, stakingManager, governance, address(withdrawalQueue), rewardsVault, safetyModule
        );
    }

    /*//////////////////////////////////////////////////////////////
                              UPGRADES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UnauthorizedUpgrade() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();
        address attacker = makeAddr("attacker");

        vm.expectRevert();
        vm.prank(attacker);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    /*//////////////////////////////////////////////////////////////
                           PAUSE CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_GuardianCanPauseAndUnpause() external {
        vm.expectEmit(true, true, true, true, address(vault));
        emit Paused();
        vm.prank(governance);
        vault.pause();

        vm.expectEmit(true, true, true, true, address(vault));
        emit Unpaused();
        vm.prank(governance);
        vault.unpause();
    }

    function test_RevertWhen_NonGuardianPause() external {
        vm.expectRevert();
        vm.prank(alice);
        vault.pause();
    }

    function test_RevertWhen_DepositWhilePaused() external {
        vm.prank(governance);
        vault.pause();

        asset.mint(alice, 5 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 5 * DECIMALS);

        vm.expectRevert();
        vm.prank(alice);
        vault.deposit(5 * DECIMALS, alice);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL REQUESTS
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_CallsQueueWithExpectedValues() external {
        _performDeposit(alice, 20 * DECIMALS);

        uint256 rate = vault.exchangeRate();
        uint256 shares = 6 * DECIMALS;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawalRequested(1, bob, shares, expectedAssets, rate);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        assertEq(requestId, 1, "request id should start at 1");
        (address receiver, uint256 recordedShares, uint256 recordedAssets, uint256 recordedRate) =
            _queueRequestSnapshot();
        assertEq(receiver, bob, "queue receives receiver");
        assertEq(recordedShares, shares, "queue receives share amount");
        assertEq(recordedAssets, expectedAssets, "queue receives assetsExpected");
        assertEq(recordedRate, rate, "queue receives exchange rate");
    }

    /*//////////////////////////////////////////////////////////////
                          OPERATOR ACTIONS
    //////////////////////////////////////////////////////////////*/

    function test_OperatorCanCallOperatorHooks() external {
        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(0, 0, 0, 0);
        vm.prank(operator);
        vault.rebalance();

        uint256 expectedExchangeRate = vault.exchangeRate();
        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(0, 0, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AccountingUpdated(0, expectedExchangeRate, 0, 0, 0, 0, 0, expectedTimestamp);
        vm.prank(operator);
        vault.updateAccounting();

        vm.expectEmit(true, true, true, true, address(vault));
        emit WithdrawalFinalized(0, 0);
        vm.prank(operator);
        uint256 used = vault.finalizeWithdrawals(0);
        assertEq(used, 0, "finalize returns zero in stub");
    }

    /*//////////////////////////////////////////////////////////////
                              UPGRADES
    //////////////////////////////////////////////////////////////*/

    function test_GovernanceCanUpgrade() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();

        vm.expectEmit(true, true, false, true, address(vault));
        emit Upgraded(address(newImplementation));

        vm.prank(governance);
        vault.upgradeToAndCall(address(newImplementation), "");

        uint256 version = OllaCoreUpgradeMock(address(vault)).version();
        assertEq(version, 2, "upgrade applied");
    }

    /*//////////////////////////////////////////////////////////////
                               DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_DepositMintsAtExchangeRate() external {
        uint256 depositAssetAmountAlice = 100 * DECIMALS;
        uint256 firstShares = _performDeposit(alice, depositAssetAmountAlice);
        assertEq(firstShares, depositAssetAmountAlice, "first deposit: 1:1 shares at zero supply");

        vault.exposedIncreaseRewardsVaultBalance(50 * DECIMALS);

        uint256 totalAssetsBeforeSecondDeposit = vault.totalAssets();
        uint256 totalSharesBeforeSecondDeposit = stAztec.totalSupply();

        uint256 depositAssetAmountBob = 50 * DECIMALS;
        uint256 expectedShares = (depositAssetAmountBob)
        .mulDiv(totalSharesBeforeSecondDeposit, totalAssetsBeforeSecondDeposit, Math.Rounding.Floor);
        uint256 secondShares = _performDeposit(bob, depositAssetAmountBob);

        assertEq(secondShares, expectedShares, "second deposit: shares follow exchange rate");
    }

    function test_DepositsAreInstant() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);

        assertEq(stAztec.balanceOf(alice), shares, "shares minted");
        assertEq(vault.totalAssets(), 10 * DECIMALS, "assets buffered");
        IOllaCore.FlowCounters memory flows = vault.flowCounters();
        assertEq(flows.cumulativeDeposits, 10 * DECIMALS, "cumulative deposits updated");
    }

    /*//////////////////////////////////////////////////////////////
                          ACCOUNTING STATE
    //////////////////////////////////////////////////////////////*/

    function test_BucketGettersReflectState() external {
        uint256 assets = 10 * DECIMALS;
        uint256 staked = 6 * DECIMALS;
        uint256 rewardsVaultBalance = 4 * DECIMALS;
        uint256 rewardsDelta = 2 * DECIMALS;
        uint256 slashingDelta = 1 * DECIMALS;

        _performDeposit(alice, assets);
        vm.prank(operator);
        vault.exposedIncreaseStakedPrincipal(staked);
        vm.prank(operator);
        vault.exposedIncreaseRewardsVaultBalance(rewardsVaultBalance);
        vm.prank(operator);
        vault.exposedSetRewardsDelta(rewardsDelta);
        vm.prank(operator);
        vault.exposedSetSlashingDelta(slashingDelta);

        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertEq(accounting.bufferedAssets, assets, "bufferedAssets matches deposited assets");
        assertEq(accounting.stakedPrincipal, staked, "stakedPrincipal matches staked amount");
        assertEq(accounting.rewardsVaultBalance, rewardsVaultBalance, "rewardsVaultBalance matches rewards vault");
        assertEq(accounting.rewardsDelta, rewardsDelta, "rewardsDelta matches rewards delta");
        assertEq(accounting.slashingDelta, slashingDelta, "slashingDelta matches slashing delta");
        assertEq(
            vault.totalAssets(),
            assets + staked + rewardsVaultBalance + rewardsDelta - slashingDelta,
            "totalAssets sums buckets"
        );
    }

    function test_StakingAndUnstakingDoesNotAffectBucketBalances() external {
        uint256 assets = 12 * DECIMALS;

        _performDeposit(alice, assets);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 bufferedBefore = accountingBefore.bufferedAssets;
        uint256 stakedBefore = accountingBefore.stakedPrincipal;
        uint256 rewardsVaultBefore = accountingBefore.rewardsVaultBalance;
        uint256 rewardsDeltaBefore = accountingBefore.rewardsDelta;
        uint256 slashingDeltaBefore = accountingBefore.slashingDelta;

        vault.exposedStake(assets / 2);
        vault.exposedUnstake(assets / 2);

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(accountingAfter.bufferedAssets, bufferedBefore, "buffered unchanged");
        assertEq(accountingAfter.stakedPrincipal, stakedBefore, "staked unchanged");
        assertEq(accountingAfter.rewardsVaultBalance, rewardsVaultBefore, "rewards vault unchanged");
        assertEq(accountingAfter.rewardsDelta, rewardsDeltaBefore, "rewards delta unchanged");
        assertEq(accountingAfter.slashingDelta, slashingDeltaBefore, "slashing delta unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_TotalAssetsComposition(
        uint96 buffered,
        uint96 staked,
        uint96 rewardsVaultBalance,
        uint96 rewardsDelta,
        uint96 slashingDeltaSeed
    ) external {
        buffered = uint96(bound(buffered, 1, type(uint96).max));
        staked = uint96(bound(staked, 1, type(uint96).max));
        rewardsVaultBalance = uint96(bound(rewardsVaultBalance, 1, type(uint96).max));
        rewardsDelta = uint96(bound(rewardsDelta, 0, type(uint96).max));

        uint256 positiveTotal =
            uint256(buffered) + uint256(staked) + uint256(rewardsVaultBalance) + uint256(rewardsDelta);
        uint256 slashingDelta = bound(uint256(slashingDeltaSeed), 0, positiveTotal);

        asset.mint(address(vault), buffered);
        vault.exposedIncreaseBuffered(buffered);
        vault.exposedIncreaseStakedPrincipal(staked);
        vault.exposedIncreaseRewardsVaultBalance(rewardsVaultBalance);
        vault.exposedSetRewardsDelta(rewardsDelta);
        vault.exposedSetSlashingDelta(slashingDelta);

        assertEq(vault.totalAssets(), positiveTotal - slashingDelta, "totalAssets includes slashing delta");
    }

    function testFuzz_ComputeNetFlows(
        uint96 cumulativeDeposits,
        uint96 cumulativeWithdrawals,
        uint96 latestReportCumulativeDeposits,
        uint96 latestReportCumulativeWithdrawals
    ) external {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: cumulativeDeposits,
            cumulativeWithdrawals: cumulativeWithdrawals,
            latestReportCumulativeDeposits: latestReportCumulativeDeposits,
            latestReportCumulativeWithdrawals: latestReportCumulativeWithdrawals
        });

        (uint256 netFlows, uint256 netDeposits, uint256 netWithdrawals) = vault.exposedComputeNetFlows(flows);

        uint256 expectedNetDeposits = cumulativeDeposits > latestReportCumulativeDeposits
            ? cumulativeDeposits - latestReportCumulativeDeposits
            : 0;
        uint256 expectedNetWithdrawals = cumulativeWithdrawals > latestReportCumulativeWithdrawals
            ? cumulativeWithdrawals - latestReportCumulativeWithdrawals
            : 0;
        uint256 expectedNetFlows =
            expectedNetDeposits > expectedNetWithdrawals ? expectedNetDeposits - expectedNetWithdrawals : 0;

        assertEq(netDeposits, expectedNetDeposits, "net deposits fuzz");
        assertEq(netWithdrawals, expectedNetWithdrawals, "net withdrawals fuzz");
        assertEq(netFlows, expectedNetFlows, "net flows fuzz");
    }

    function testFuzz_ComputeGrossRewards(uint96 oldTotalAssets, uint96 newTotalAssets, uint96 netFlows) external {
        uint256 grossRewards = vault.exposedComputeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        uint256 changeInAssets = newTotalAssets > oldTotalAssets ? newTotalAssets - oldTotalAssets : 0;
        uint256 expectedGross = changeInAssets > netFlows ? changeInAssets - netFlows : 0;

        assertEq(grossRewards, expectedGross, "gross rewards fuzz");
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
        emit AccountingUpdated(depositAmount, expectedRate, 0, depositAmount, 0, 0, 0, expectedTimestamp);
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

    /*//////////////////////////////////////////////////////////////
                       ACCOUNTING CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    function test_ComputeNetFlows() external {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: 12 * DECIMALS,
            cumulativeWithdrawals: 4 * DECIMALS,
            latestReportCumulativeDeposits: 5 * DECIMALS,
            latestReportCumulativeWithdrawals: 1 * DECIMALS
        });

        (uint256 netFlows, uint256 netDeposits, uint256 netWithdrawals) = vault.exposedComputeNetFlows(flows);

        assertEq(netDeposits, 7 * DECIMALS, "net deposits");
        assertEq(netWithdrawals, 3 * DECIMALS, "net withdrawals");
        assertEq(netFlows, 4 * DECIMALS, "net flows");
    }

    function test_ComputeTotalAssets() external {
        IOllaCore.AccountingState memory buckets = IOllaCore.AccountingState({
            bufferedAssets: 3 * DECIMALS,
            stakedPrincipal: 4 * DECIMALS,
            rewardsVaultBalance: 2 * DECIMALS,
            rewardsDelta: 1 * DECIMALS,
            slashingDelta: 5 * DECIMALS
        });

        uint256 totalAssets = vault.exposedComputeTotalAssets(buckets);

        assertEq(totalAssets, 5 * DECIMALS, "total assets computed");
    }

    function test_ComputeGrossRewards() external {
        uint256 grossRewards = vault.exposedComputeGrossRewards(100 * DECIMALS, 130 * DECIMALS, 20 * DECIMALS);

        assertEq(grossRewards, 10 * DECIMALS, "gross rewards computed");
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
        uint256 rewards = 5 * DECIMALS;
        uint256 slashing = 2 * DECIMALS;

        _performDeposit(alice, depositAmount);
        vm.prank(operator);
        vault.exposedSetRewardsDelta(rewards);
        vm.prank(operator);
        vault.exposedSetSlashingDelta(slashing);

        uint256 expectedTotalAssets = depositAmount + rewards - slashing;
        uint256 expectedRate = expectedTotalAssets.mulDiv(DECIMALS, stAztec.totalSupply(), Math.Rounding.Floor);
        uint256 expectedGrossRewards = rewards > slashing ? rewards - slashing : 0;

        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(rewards, slashing, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AccountingUpdated(
            expectedTotalAssets, expectedRate, expectedGrossRewards, depositAmount, 0, 0, 0, expectedTimestamp
        );
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        IOllaCore.FlowCounters memory flowsAfter = vault.flowCounters();
        assertEq(reportAfter.totalAssets, expectedTotalAssets, "lastTotalAssets updated");
        assertEq(reportAfter.exchangeRate, expectedRate, "stored exchange rate updated");
        assertEq(flowsAfter.latestReportCumulativeDeposits, depositAmount, "latestReportCumulativeDeposits updated");
        assertEq(flowsAfter.latestReportCumulativeWithdrawals, 0, "latestReportCumulativeWithdrawals updated");
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_BufferedBalanceMismatch() external {
        uint256 assets = 10 * DECIMALS;
        uint256 bonus = 2 * DECIMALS;

        _performDeposit(alice, assets);
        asset.mint(address(vault), bonus);

        vm.expectRevert(
            abi.encodeWithSelector(OllaCore.OllaCore__BufferedBalanceMismatch.selector, assets, assets + bonus)
        );
        vault.exposedSyncBufferedWithBalance();
    }

    function test_EmitDepositEvent() external {
        uint256 assets = 10 * DECIMALS;

        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, alice, assets, assets);

        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    /*//////////////////////////////////////////////////////////////
                           INIT VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_InitializeZeroAddress() external {
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        OllaCore newVault = OllaCore(address(proxy));
        StAztec newStAztec = new StAztec(address(newVault));
        MockStakingManager newStakingManager = new MockStakingManager();

        address newGovernance = makeAddr("governance");

        address newWithdrawalQueue = makeAddr("withdrawalQueue");
        address newRewardsVault = makeAddr("rewardsVault");
        address newSafetyModule = makeAddr("safetyModule");

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "asset_"));
        newVault.initialize(
            IERC20(address(0)),
            newStAztec,
            newStakingManager,
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "stAztec_"));
        newVault.initialize(
            asset,
            IStAztec(address(0)),
            newStakingManager,
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "stakingManager_"));
        newVault.initialize(
            asset,
            newStAztec,
            IStakingManager(address(0)),
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "governance_"));
        newVault.initialize(
            asset, newStAztec, newStakingManager, address(0), newWithdrawalQueue, newRewardsVault, newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "withdrawalQueue_"));
        newVault.initialize(
            asset, newStAztec, newStakingManager, newGovernance, address(0), newRewardsVault, newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "rewardsVault_"));
        newVault.initialize(
            asset, newStAztec, newStakingManager, newGovernance, newWithdrawalQueue, address(0), newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "safetyModule_"));
        newVault.initialize(
            asset, newStAztec, newStakingManager, newGovernance, newWithdrawalQueue, newRewardsVault, address(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZED DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositMintsShares(uint96 assets) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        uint256 shares = _performDeposit(alice, assets);

        assertEq(shares, assets, "shares minted at 1:1");
        assertEq(stAztec.balanceOf(alice), shares, "shares balance");
        assertEq(vault.totalAssets(), assets, "assets buffered");
    }
}
