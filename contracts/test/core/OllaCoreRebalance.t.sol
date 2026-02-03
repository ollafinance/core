// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MaliciousReentrantStakingManager } from "test/mocks/MaliciousReentrantStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

contract OllaCoreRebalanceTest is Test {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardsDelta(uint256 delta);
    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);
    event UnstakedFundsClaimed(uint256 amount);
    event WithdrawalFinalized(uint256 available, uint256 used);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal operator;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        operator = makeAddr("operator");
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation), abi.encodeCall(WithdrawalQueue.initialize, (address(vault), governance))
        );
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));

        // Configure staking manager to mint rewards directly to rewards vault
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

    function _requestWithdrawal(address owner, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, owner);
        return requestId;
    }

    /*//////////////////////////////////////////////////////////////
                               REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_HarvestsRewardsAndUpdatesCumulativeRewards() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 expectedBuffer = accountingBefore.bufferedAssets;

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.harvestRewards, ()));
        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsDelta(rewardAmount);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(rewardAmount, 0, 0, expectedBuffer);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(
            accountingAfter.cumulativeRewards,
            accountingBefore.cumulativeRewards + rewardAmount,
            "cumulative rewards updated"
        );
    }

    function test_Rebalance_ZeroRewardsEmitsAndDoesNotUpdateCumulativeRewards() external {
        uint256 depositAmount = 8 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 firstReward = 3 * DECIMALS;
        stakingManager.setHarvestedRewards(firstReward);
        vm.prank(operator);
        vault.rebalance();

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 expectedBuffer = accountingBefore.bufferedAssets;

        stakingManager.setHarvestedRewards(0);

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.harvestRewards, ()));
        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsDelta(0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(0, 0, 0, expectedBuffer);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(accountingAfter.cumulativeRewards, accountingBefore.cumulativeRewards, "cumulative rewards unchanged");
    }

    function test_Rebalance_PullUnstakedFunds_IncreasesBuffer() external {
        uint256 unstakedAmount = 5 * DECIMALS;
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(unstakedAmount);
        asset.mint(address(stakingManager), unstakedAmount);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.getUnstakedFunds, ()));
        vm.expectEmit(true, true, true, true, address(vault));
        emit UnstakedFundsClaimed(unstakedAmount);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(
            accountingAfter.bufferedAssets,
            accountingBefore.bufferedAssets + unstakedAmount,
            "buffered assets increased"
        );
    }

    function test_Rebalance_PullUnstakedFunds_NoOp() external {
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(0);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.getUnstakedFunds, ()));
        vm.prank(operator);
        vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(accountingAfter.bufferedAssets, accountingBefore.bufferedAssets, "buffered assets unchanged");
    }

    function test_Rebalance_FinalizeWithdrawals_ConsumesBuffer() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 withdrawalShares = 6 * DECIMALS;

        _performDeposit(alice, depositAmount);

        uint256 requestId = _requestWithdrawal(alice, withdrawalShares);
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 bufferBefore = accountingBefore.bufferedAssets;

        vm.expectCall(address(withdrawalQueue), abi.encodeCall(withdrawalQueue.finalizeWithdrawals, (bufferBefore)));
        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsDelta(0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit WithdrawalFinalized(bufferBefore, request.assetsExpected);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(0, request.assetsExpected, 0, bufferBefore - request.assetsExpected);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(
            accountingAfter.bufferedAssets,
            bufferBefore - request.assetsExpected,
            "buffered assets reduced by finalized amount"
        );
    }

    function test_Rebalance_FinalizeWithdrawals_QueueDrains() external {
        uint256 depositAmount = 20 * DECIMALS;
        uint256 withdrawalShares = 5 * DECIMALS;

        _performDeposit(alice, depositAmount);
        _requestWithdrawal(alice, withdrawalShares);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        vm.prank(operator);
        vault.rebalance();

        assertEq(withdrawalQueue.totalPendingAssets(), 0, "pending queue drained");
    }

    function test_Rebalance_NoOp_WhenNoRewardsNoUnstakedNoQueue() external {
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsDelta(0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(0, 0, 0, accountingBefore.bufferedAssets);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(accountingAfter.bufferedAssets, accountingBefore.bufferedAssets, "buffered assets unchanged");
    }
}

contract OllaCoreRebalanceReentrancyTest is Test {
    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MaliciousReentrantStakingManager internal stakingManager;
    address internal governance;
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal operator;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MaliciousReentrantStakingManager();
        governance = makeAddr("governance");
        operator = makeAddr("operator");
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation), abi.encodeCall(WithdrawalQueue.initialize, (address(vault), governance))
        );
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));

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

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vault.grantRole(operatorRole, address(stakingManager));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_RevertsOnReentrantGetUnstakedFunds() external {
        stakingManager.setReentry(vault, MaliciousReentrantStakingManager.ReentryAction.Rebalance);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(operator);
        vault.rebalance();
    }
}
