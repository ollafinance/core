// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MaliciousReentrantStakingManager } from "test/mocks/MaliciousReentrantStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

contract InconsistentWithdrawalQueue is IWithdrawalQueue {
    uint256 internal _totalPendingAssets;
    address internal _core;

    function setTotalPendingAssets(uint256 amount) external {
        _totalPendingAssets = amount;
    }

    function initialize(address core_, address) external override {
        _core = core_;
    }

    function requestWithdrawal(address, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function finalizeWithdrawals(uint256 available) external override returns (uint256 used, uint256 finalizedCount) {
        uint256 usedAssets = 1e18;
        if (available < usedAssets || _totalPendingAssets < usedAssets) {
            return (0, 0);
        }

        _totalPendingAssets -= usedAssets;
        return (usedAssets, 0);
    }

    function claimWithdrawal(uint256) external pure override returns (uint256) {
        return 0;
    }

    function nextRequestId() external pure override returns (uint256) {
        return 1;
    }

    function nextPendingId() external pure override returns (uint256) {
        return 1;
    }

    function totalPendingAssets() external view override returns (uint256) {
        return _totalPendingAssets;
    }

    function getRequest(uint256) external pure override returns (WithdrawalRequest memory request) {
        return request;
    }

    function nextUnfinalized() external pure override returns (uint256) {
        return 1;
    }

    function core() external view override returns (address) {
        return _core;
    }
}

contract MismatchWithdrawalQueue is IWithdrawalQueue {
    uint256 internal _totalPendingAssets;
    address internal _core;

    function setTotalPendingAssets(uint256 amount) external {
        _totalPendingAssets = amount;
    }

    function initialize(address core_, address) external override {
        _core = core_;
    }

    function requestWithdrawal(address, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function finalizeWithdrawals(uint256 available)
        external
        pure
        override
        returns (uint256 used, uint256 finalizedCount)
    {
        uint256 usedAssets = 1e18;
        if (available < usedAssets) {
            return (0, 0);
        }

        return (usedAssets, 1);
    }

    function claimWithdrawal(uint256) external pure override returns (uint256) {
        return 0;
    }

    function nextRequestId() external pure override returns (uint256) {
        return 1;
    }

    function nextPendingId() external pure override returns (uint256) {
        return 1;
    }

    function totalPendingAssets() external view override returns (uint256) {
        return _totalPendingAssets;
    }

    function getRequest(uint256) external pure override returns (WithdrawalRequest memory request) {
        return request;
    }

    function nextUnfinalized() external pure override returns (uint256) {
        return 1;
    }

    function core() external view override returns (address) {
        return _core;
    }
}

contract OllaCoreRebalanceTest is Test {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardsDelta(uint256 delta);
    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);
    event UnstakedFundsClaimed(uint256 amount);
    event WithdrawalFinalized(uint256 available, uint256 used);
    event UnstakeInitiated(uint256 requested, uint256 initiated);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant DEFAULT_REBALANCE_GAS_THRESHOLD = 180_000;

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

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockAccountingStakingManager();
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
                           GAS THRESHOLD
    //////////////////////////////////////////////////////////////*/

    function test_DefaultRebalanceGasThreshold() external view {
        assertEq(vault.rebalanceGasThreshold(), DEFAULT_REBALANCE_GAS_THRESHOLD, "default gas threshold");
        assertEq(stakingManager.gasThreshold(), DEFAULT_REBALANCE_GAS_THRESHOLD, "staking manager threshold set");
    }

    function test_RevertWhen_NonAdminSetsRebalanceGasThreshold() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setRebalanceGasThreshold(200_000);
    }

    function test_RevertWhen_OperatorWithoutAdminSetsRebalanceGasThreshold() external {
        address otherOperator = makeAddr("otherOperator");
        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.prank(governance);
        vault.grantRole(operatorRole, otherOperator);

        assertTrue(vault.hasRole(operatorRole, otherOperator), "test operator role");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, otherOperator, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(otherOperator);
        vault.setRebalanceGasThreshold(200_000);
    }

    function test_SetRebalanceGasThreshold_UpdatesAndForwards() external {
        uint256 newThreshold = 240_000;

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.setGasThreshold, (newThreshold)));

        vm.prank(governance);
        vault.setRebalanceGasThreshold(newThreshold);

        assertEq(vault.rebalanceGasThreshold(), newThreshold, "core gas threshold updated");
        assertEq(stakingManager.gasThreshold(), newThreshold, "staking manager threshold forwarded");
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
        // Expected buffer after rebalance includes rewards pulled from rewards vault
        uint256 expectedBuffer = accountingBefore.bufferedAssets + rewardAmount;

        vm.prank(governance);
        vault.setTargetBufferedAssets(expectedBuffer);

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

        vm.prank(governance);
        vault.setTargetBufferedAssets(expectedBuffer);

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
        uint256 expectedBuffer = accountingBefore.bufferedAssets + unstakedAmount;

        vm.prank(governance);
        vault.setTargetBufferedAssets(expectedBuffer);

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.getUnstakedFunds, ()));
        vm.expectEmit(true, true, true, true, address(vault));
        emit UnstakedFundsClaimed(unstakedAmount);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(accountingAfter.bufferedAssets, expectedBuffer, "buffered assets increased");
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
        uint256 targetBufferedAssets = 4 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        uint256 requestId = _requestWithdrawal(alice, withdrawalShares);
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 bufferBefore = accountingBefore.bufferedAssets;
        uint256 bufferAfterFinalize = bufferBefore - request.assetsExpected;
        uint256 expectedStaked = bufferAfterFinalize - targetBufferedAssets;

        vm.expectCall(address(withdrawalQueue), abi.encodeCall(withdrawalQueue.finalizeWithdrawals, (bufferBefore)));
        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsDelta(0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit WithdrawalFinalized(bufferBefore, request.assetsExpected);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(0, request.assetsExpected, expectedStaked, bufferAfterFinalize);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(accountingAfter.bufferedAssets, bufferAfterFinalize, "buffered assets reduced by finalize");
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

    function test_Rebalance_FinalizeWithdrawals_NoLiquidityNoEvent() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 targetBuffered = 0;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBuffered);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(depositAmount);
        stakingManager.setTotalStaked(depositAmount);

        vm.prank(operator);
        vault.rebalance();

        _requestWithdrawal(alice, depositAmount);

        vm.recordLogs();
        vm.prank(operator);
        vault.rebalance();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic = keccak256("WithdrawalFinalized(uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(vault) && entries[i].topics[0] == topic) {
                found = true;
                break;
            }
        }

        assertFalse(found, "should not emit WithdrawalFinalized without liquidity");
        assertEq(withdrawalQueue.totalPendingAssets(), depositAmount, "pending assets unchanged");
        assertEq(vault.accountingState().bufferedAssets, targetBuffered, "buffer unchanged");
    }

    function test_Rebalance_PullUnstaked_WaitsForExitableUnstakes() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 withdrawalShares = 4 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(depositAmount);

        uint256 requestId = _requestWithdrawal(alice, withdrawalShares);
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setWithdrawableUnstakes(1);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 pendingBefore = withdrawalQueue.totalPendingAssets();

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progressAfterFirst = vault.rebalanceProgress();
        assertEq(
            uint256(progressAfterFirst.step),
            uint256(IOllaCore.RebalanceStep.PullUnstaked),
            "rebalance should hold at pull unstaked while exitable unstakes"
        );
        assertEq(withdrawalQueue.totalPendingAssets(), pendingBefore, "pending assets unchanged with exitable unstakes");
        assertEq(
            vault.accountingState().bufferedAssets,
            accountingBefore.bufferedAssets,
            "buffer unchanged with exitable unstakes"
        );

        stakingManager.setWithdrawableUnstakes(0);

        uint256 bufferBeforeFinalize = vault.accountingState().bufferedAssets;
        vm.expectCall(
            address(withdrawalQueue), abi.encodeCall(withdrawalQueue.finalizeWithdrawals, (bufferBeforeFinalize))
        );

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progressAfterSecond = vault.rebalanceProgress();
        assertTrue(
            uint256(progressAfterSecond.step) != uint256(IOllaCore.RebalanceStep.PullUnstaked),
            "rebalance should advance after pending unstakes cleared"
        );
        assertEq(withdrawalQueue.totalPendingAssets(), 0, "pending assets finalized after pending unstakes cleared");
        assertEq(
            vault.accountingState().bufferedAssets,
            bufferBeforeFinalize - request.assetsExpected,
            "buffer reduced after finalize"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        REBALANCE PARTIAL PROGRESS
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_ReturnsPartialProgress_WhenGasStopsAtPullUnstaked() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 rewardAmount = 3 * DECIMALS;

        _performDeposit(alice, depositAmount);
        stakingManager.setHarvestedRewards(rewardAmount);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 expectedBuffer = accountingBefore.bufferedAssets + rewardAmount;

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[6] memory gasOptions = [uint256(120_000), 140_000, 160_000, 180_000, 200_000, 220_000];

        for (uint256 i = 0; i < gasOptions.length; i++) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success, bytes memory data) =
                address(vault).call{ gas: gasOptions[i] }(abi.encodeCall(vault.rebalance, ()));
            if (!success) {
                continue;
            }
            IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.PullUnstaked) {
                (
                    uint256 loopRewardsDelta,
                    uint256 loopFinalizedAmount,
                    uint256 loopStakedAmount,
                    uint256 loopResultingBuffer
                ) = abi.decode(data, (uint256, uint256, uint256, uint256));
                if (loopRewardsDelta == rewardAmount && loopFinalizedAmount == 0 && loopStakedAmount == 0) {
                    selectedGas = gasOptions[i];
                    assertEq(loopResultingBuffer, expectedBuffer, "buffer should include harvested rewards");
                    break;
                }
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for pull-unstaked stop");

        vm.revertToState(snapshotId);
        vm.prank(operator);
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) =
            vault.rebalance{ gas: selectedGas }();

        IOllaCore.RebalanceProgress memory progressAfter = vault.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.PullUnstaked),
            "rebalance should stop at pull unstaked"
        );
        assertEq(rewardsDelta, rewardAmount, "rewards delta should return harvested amount");
        assertEq(finalizedAmount, 0, "finalized amount should be zero on partial progress");
        assertEq(stakedAmount, 0, "staked amount should be zero on partial progress");
        assertEq(resultingBuffer, expectedBuffer, "buffer should include harvested rewards");
    }

    function test_Rebalance_ReturnsPartialProgress_WhenGasStopsAtFinalizeWithdrawals() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 rewardAmount = 4 * DECIMALS;
        uint256 unstakedAmount = 1 * DECIMALS;

        _performDeposit(alice, depositAmount);
        stakingManager.setHarvestedRewards(rewardAmount);
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(unstakedAmount);
        asset.mint(address(stakingManager), unstakedAmount);
        stakingManager.setGasBurnTarget(60_000);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 expectedBuffer = accountingBefore.bufferedAssets + rewardAmount + unstakedAmount;

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;

        for (uint256 gasLimit = 250_000; gasLimit <= 800_000; gasLimit += 25_000) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success, bytes memory data) =
                address(vault).call{ gas: gasLimit }(abi.encodeCall(vault.rebalance, ()));
            if (!success) {
                continue;
            }

            IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.FinalizeWithdrawals) {
                (
                    uint256 loopRewardsDelta,
                    uint256 loopFinalizedAmount,
                    uint256 loopStakedAmount,
                    uint256 loopResultingBuffer
                ) = abi.decode(data, (uint256, uint256, uint256, uint256));
                if (loopRewardsDelta == rewardAmount && loopFinalizedAmount == 0 && loopStakedAmount == 0) {
                    selectedGas = gasLimit;
                    assertEq(loopResultingBuffer, expectedBuffer, "buffer should include harvested rewards");
                    break;
                }
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for finalize stop");

        vm.revertToState(snapshotId);
        vm.prank(operator);
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) =
            vault.rebalance{ gas: selectedGas }();

        IOllaCore.RebalanceProgress memory progressAfter = vault.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.FinalizeWithdrawals),
            "rebalance should stop at finalize withdrawals"
        );
        assertEq(rewardsDelta, rewardAmount, "rewards delta should return harvested amount");
        assertEq(finalizedAmount, 0, "finalized amount should be zero on partial progress");
        assertEq(stakedAmount, 0, "staked amount should be zero on partial progress");
        assertEq(resultingBuffer, expectedBuffer, "buffer should include harvested rewards");
    }

    function test_Rebalance_LowGas_PullUnstakedResumesAcrossCalls() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 unstakedAmount = 3 * DECIMALS;

        _performDeposit(alice, depositAmount);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(unstakedAmount);
        stakingManager.setGasBurnTarget(90_000);
        asset.mint(address(stakingManager), unstakedAmount);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 expectedBuffer = accountingBefore.bufferedAssets + unstakedAmount;

        vm.prank(governance);
        vault.setTargetBufferedAssets(expectedBuffer);

        vm.prank(operator);
        vault.rebalance{ gas: 400_000 }();

        IOllaCore.RebalanceProgress memory progressAfter = vault.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.FinalizeWithdrawals),
            "rebalance should pause after pull unstaked under low gas"
        );

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progressFinal = vault.rebalanceProgress();
        assertEq(
            uint256(progressFinal.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should complete after follow-up"
        );
    }

    function test_Rebalance_FinalizeWithdrawals_BoundedGasProgresses() external {
        uint256 totalRequests = 200;
        uint256 requestShares = 1 * DECIMALS;
        uint256 depositAmount = totalRequests * requestShares;

        _performDeposit(alice, depositAmount);

        for (uint256 i = 0; i < totalRequests; i++) {
            _requestWithdrawal(alice, requestShares);
        }

        vm.prank(governance);
        vault.setTargetBufferedAssets(0);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);

        uint256 totalPendingBefore = withdrawalQueue.totalPendingAssets();
        if (vault.accountingState().bufferedAssets < totalPendingBefore) {
            uint256 bufferGap = totalPendingBefore - vault.accountingState().bufferedAssets;
            asset.mint(address(vault), bufferGap);
            vm.prank(operator);
            vault.reconcileBufferedAssets();
        }

        uint256 bufferBefore = vault.accountingState().bufferedAssets;
        uint256 snapshotId = vm.snapshotState();

        uint256 selectedGas;
        uint256 finalizedObserved;
        uint256 bufferObserved;
        uint256[6] memory gasOptions = [uint256(120_000), 140_000, 160_000, 180_000, 200_000, 220_000];

        for (uint256 i = 0; i < gasOptions.length; i++) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success, bytes memory data) =
                address(vault).call{ gas: gasOptions[i] }(abi.encodeCall(vault.rebalance, ()));

            if (!success) {
                continue;
            }

            (, uint256 finalizedCandidate,, uint256 bufferCandidate) =
                abi.decode(data, (uint256, uint256, uint256, uint256));
            if (finalizedCandidate > 0 && finalizedCandidate < totalPendingBefore) {
                selectedGas = gasOptions[i];
                finalizedObserved = finalizedCandidate;
                bufferObserved = bufferCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            vault.rebalance();

            assertEq(withdrawalQueue.totalPendingAssets(), 0, "queue should drain in one call");
            assertEq(vault.accountingState().bufferedAssets, bufferBefore - totalPendingBefore, "buffer should drain");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(operator);
        (, uint256 finalizedAmount,, uint256 bufferAfter) = vault.rebalance{ gas: selectedGas }();

        assertEq(finalizedAmount, finalizedObserved, "finalized amount should match probe");
        assertEq(bufferAfter, bufferObserved, "buffer should match probe");
        assertEq(
            withdrawalQueue.totalPendingAssets(),
            totalPendingBefore - finalizedAmount,
            "pending assets should decrease by finalized amount"
        );
        assertEq(
            vault.accountingState().bufferedAssets,
            bufferBefore - finalizedAmount,
            "buffered assets should decrease by finalized amount"
        );

        for (uint256 i = 0; i < 50; i++) {
            vm.prank(operator);
            vault.rebalance();
            if (withdrawalQueue.totalPendingAssets() == 0) {
                break;
            }
        }

        assertEq(withdrawalQueue.totalPendingAssets(), 0, "queue should drain after follow-up rebalance");
    }

    function test_Rebalance_Liveness_ZeroUnstakeReturn_Recovers() external {
        uint256 bufferAmount = 5 * DECIMALS;
        uint256 targetBufferedAssets = 20 * DECIMALS;

        asset.mint(address(vault), bufferAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);
        stakingManager.setUnstakeReturnAmount(0);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progressAfter = vault.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should advance when no unstake capacity"
        );
        assertEq(progressAfter.unstakeRemaining, 0, "unstake remaining should clear when no capacity");

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progressFinal = vault.rebalanceProgress();
        assertEq(
            uint256(progressFinal.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should remain done after recovery"
        );
    }

    function test_Rebalance_Liveness_ZeroUnstakeReturn_WithCapacity_DoesNotAdvance() external {
        uint256 bufferAmount = 5 * DECIMALS;
        uint256 targetBufferedAssets = 20 * DECIMALS;

        asset.mint(address(vault), bufferAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);
        stakingManager.setUnstakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(1);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progressAfter = vault.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.InitiateUnstake),
            "rebalance should stay in initiate unstake with capacity"
        );
        assertEq(
            progressAfter.unstakeRemaining,
            targetBufferedAssets - bufferAmount,
            "unstake remaining should persist when capacity exists"
        );
    }

    function test_Rebalance_Bounded_StateMachineCompletesAndEmitsOnce() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 withdrawalShares = 20 * DECIMALS;
        uint256 targetBufferedAssets = 10 * DECIMALS;
        uint256 rewardAmount = 5 * DECIMALS;
        uint256 unstakedAmount = 8 * DECIMALS;

        _performDeposit(alice, depositAmount);
        _requestWithdrawal(alice, withdrawalShares);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(rewardAmount);
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(unstakedAmount);
        asset.mint(address(stakingManager), unstakedAmount);
        stakingManager.setStakeReturnAmount(20 * DECIMALS);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        IOllaCore.RebalanceStep observedStep = IOllaCore.RebalanceStep.Done;
        uint256[6] memory gasOptions = [uint256(190_000), 210_000, 230_000, 250_000, 270_000, 290_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success,) = address(vault).call{ gas: gasOptions[i] }(abi.encodeCall(vault.rebalance, ()));
            if (!success) {
                continue;
            }
            IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
            if (
                progress.step == IOllaCore.RebalanceStep.PullUnstaked
                    || progress.step == IOllaCore.RebalanceStep.FinalizeWithdrawals
            ) {
                selectedGas = gasOptions[i];
                observedStep = progress.step;
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for early-step rebalance");

        vm.revertToState(snapshotId);
        vm.recordLogs();
        vm.prank(operator);
        vault.rebalance{ gas: selectedGas }();

        IOllaCore.RebalanceProgress memory progressAfter = vault.rebalanceProgress();
        assertEq(uint256(progressAfter.step), uint256(observedStep), "rebalance should stop at early step");

        Vm.Log[] memory earlyLogs = vm.getRecordedLogs();
        bytes32 rebalancedSelector = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");
        bool earlyEmit;
        for (uint256 i; i < earlyLogs.length; ++i) {
            if (earlyLogs[i].topics[0] == rebalancedSelector) {
                earlyEmit = true;
                break;
            }
        }
        assertFalse(earlyEmit, "should not emit Rebalanced before completion");

        uint256 rebalancedEvents;
        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            vm.recordLogs();
            vm.prank(operator);
            vault.rebalance();
            Vm.Log[] memory entries = vm.getRecordedLogs();
            for (uint256 j; j < entries.length; ++j) {
                if (entries[j].topics[0] == rebalancedSelector) {
                    rebalancedEvents += 1;
                }
            }
            IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.Done) {
                break;
            }
        }

        IOllaCore.RebalanceProgress memory progressFinal = vault.rebalanceProgress();
        assertEq(uint256(progressFinal.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should finish");
        assertEq(progressFinal.stakeRemaining, 0, "stake remaining should clear");
        assertEq(progressFinal.unstakeRemaining, 0, "unstake remaining should clear");
        assertEq(rebalancedEvents, 1, "Rebalanced should emit once at completion");
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

    function test_Rebalance_Unstake_TargetBufferedAssetsShortfall_NoPending() external {
        uint256 bufferAmount = 10 * DECIMALS;
        uint256 targetBufferedAssets = 30 * DECIMALS;

        asset.mint(address(vault), bufferAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        uint256 shortfall = targetBufferedAssets - bufferAmount;

        vm.expectEmit(true, true, true, true, address(vault));
        emit UnstakeInitiated(shortfall, shortfall);

        vm.prank(operator);
        vault.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), shortfall, "unstake replenishes buffer");
    }

    function test_Rebalance_Unstake_PendingExceedsBuffer() external {
        uint256 pendingAssets = 25 * DECIMALS;

        vm.prank(address(vault));
        withdrawalQueue.requestWithdrawal(alice, 1 * DECIMALS, pendingAssets, 1e18);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.prank(operator);
        vault.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), pendingAssets, "unstake initiated");
    }

    function test_Rebalance_Unstake_PendingPlusTargetBufferedAssets() external {
        uint256 pendingAssets = 25 * DECIMALS;
        uint256 targetBufferedAssets = 5 * DECIMALS;

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        vm.prank(address(vault));
        withdrawalQueue.requestWithdrawal(alice, 1 * DECIMALS, pendingAssets, 1e18);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.prank(operator);
        vault.rebalance();

        assertEq(
            stakingManager.lastUnstakeAmount(),
            pendingAssets + targetBufferedAssets,
            "unstake uses pending plus target buffer"
        );
    }

    function test_Rebalance_Unstake_NoOpWhenBufferCoversPending() external {
        uint256 bufferAmount = 30 * DECIMALS;
        uint256 pendingAssets = 25 * DECIMALS;

        asset.mint(address(vault), bufferAmount);
        vm.prank(address(vault));
        withdrawalQueue.requestWithdrawal(alice, 1 * DECIMALS, pendingAssets, 1e18);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.prank(operator);
        vault.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), 0, "unstake not initiated");
    }

    function test_Rebalance_Unstake_PendingUnstakesReduceInitiation() external {
        uint256 pendingAssets = 30 * DECIMALS;
        uint256 pendingUnstakes = 12 * DECIMALS;

        vm.prank(address(vault));
        withdrawalQueue.requestWithdrawal(alice, 1 * DECIMALS, pendingAssets, 1e18);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(pendingUnstakes);

        vm.prank(operator);
        vault.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), pendingAssets - pendingUnstakes, "unstake reduced by pending");
    }

    function test_Rebalance_Unstake_NoUnitRounding() external {
        uint256 pendingAssets = 210 * DECIMALS;

        vm.prank(address(vault));
        withdrawalQueue.requestWithdrawal(alice, 1 * DECIMALS, pendingAssets, 1e18);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit UnstakeInitiated(pendingAssets, pendingAssets);

        vm.prank(operator);
        vault.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), pendingAssets, "unstake uses requested amount");
    }

    /*//////////////////////////////////////////////////////////////
                     ATTESTER STATE STALENESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Rebalance self-heals stale attester state via the ComputeAttesterState step
    /// instead of reverting. The step calls computeAttesterState() which refreshes the timestamp,
    /// allowing subsequent accounting reads (totalStaked, getSlashingDelta) to succeed.
    function test_Rebalance_SelfHealsStaleAttesterState() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setTotalStaked(5 * DECIMALS);
        (uint256 lastUpdated,,) = stakingManager.getAttesterStateLiveness();

        uint256 maxAge = 1 hours;
        stakingManager.setAttesterStateMaxAge(maxAge);

        vm.warp(lastUpdated + maxAge + 1);

        // Rebalance should succeed — the ComputeAttesterState step refreshes the stale state
        vm.prank(operator);
        vault.rebalance();

        // Verify the attester state is no longer stale after rebalance
        (uint256 updatedAt,, bool isStale) = stakingManager.getAttesterStateLiveness();
        assertEq(updatedAt, block.timestamp, "attester state timestamp should be current");
        assertFalse(isStale, "attester state should not be stale after rebalance");
    }

    /*//////////////////////////////////////////////////////////////
                             STAKE SURPLUS
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_StakeSurplus_UsesActualStakedAmount() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 targetBufferedAssets = 10 * DECIMALS;
        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        uint256 actualStaked = 64 * DECIMALS;
        stakingManager.setStakeReturnAmount(actualStaked);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 stakeable = accountingBefore.bufferedAssets - targetBufferedAssets;
        uint256 expectedBufferAfter = accountingBefore.bufferedAssets - actualStaked;
        uint256 expectedStakedPrincipal = accountingBefore.stakedPrincipal + actualStaked;

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.stake, (stakeable)));

        vm.prank(operator);
        (,, uint256 stakedAmount, uint256 resultingBuffer) = vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(stakedAmount, actualStaked, "staked amount uses staking manager return");
        assertEq(resultingBuffer, expectedBufferAfter, "resulting buffer uses actual staked");
        assertEq(accountingAfter.bufferedAssets, expectedBufferAfter, "buffered assets reduced by actual staked");
        assertEq(
            accountingAfter.stakedPrincipal, expectedStakedPrincipal, "staked principal increased by actual staked"
        );
    }

    function test_Rebalance_StakeSurplus_NoStakeWhenBelowTarget() external {
        uint256 depositAmount = 5 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 targetBufferedAssets = 10 * DECIMALS;
        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();

        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(0, 0, 0, accountingBefore.bufferedAssets);

        vm.prank(operator);
        (,, uint256 stakedAmount, uint256 resultingBuffer) = vault.rebalance();

        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(stakedAmount, 0, "staked amount is zero when below target");
        assertEq(resultingBuffer, accountingBefore.bufferedAssets, "buffer unchanged when below target");
        assertEq(accountingAfter.stakedPrincipal, accountingBefore.stakedPrincipal, "staked principal unchanged");
    }

    function test_Rebalance_Liveness_ZeroStakeReturn_Recovers() external {
        uint256 depositAmount = 30 * DECIMALS;
        uint256 targetBufferedAssets = 10 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progressAfter = vault.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should advance when no stake capacity"
        );
        assertEq(progressAfter.stakeRemaining, 0, "stake remaining should clear when no capacity");

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progressFinal = vault.rebalanceProgress();
        assertEq(
            uint256(progressFinal.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should remain done after recovery"
        );
    }

    function test_Rebalance_StakeSurplus_RevertsWhenStakedExceedsStakeable() external {
        uint256 depositAmount = 20 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 targetBufferedAssets = 10 * DECIMALS;
        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 stakeable = accountingBefore.bufferedAssets - targetBufferedAssets;

        stakingManager.setStakeReturnAmount(stakeable + 1);
        stakingManager.setAllowStakeReturnExceeds(true);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__StakeFailed.selector, stakeable + 1));
        vm.prank(operator);
        vault.rebalance();
    }

    function test_Rebalance_StakeSurplus_EmitsAfterFinalize() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 withdrawalShares = 20 * DECIMALS;
        uint256 targetBufferedAssets = 10 * DECIMALS;
        uint256 actualStaked = 64 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        uint256 requestId = _requestWithdrawal(alice, withdrawalShares);
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(actualStaked);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 bufferAfterFinalize = accountingBefore.bufferedAssets - request.assetsExpected;
        uint256 stakeable = bufferAfterFinalize - targetBufferedAssets;
        uint256 expectedBufferAfter = bufferAfterFinalize - actualStaked;

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.stake, (stakeable)));

        vm.recordLogs();

        vm.prank(operator);
        (,, uint256 stakedAmount, uint256 resultingBuffer) = vault.rebalance();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 finalizedSelector = keccak256("WithdrawalFinalized(uint256,uint256)");
        bytes32 rebalancedSelector = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");
        uint256 finalizedIndex = type(uint256).max;
        uint256 rebalancedIndex = type(uint256).max;

        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == finalizedSelector) {
                finalizedIndex = i;
            }
            if (entries[i].topics[0] == rebalancedSelector) {
                rebalancedIndex = i;
            }
        }

        assertTrue(finalizedIndex < rebalancedIndex, "finalize emits before rebalance");
        assertEq(stakedAmount, actualStaked, "staked amount uses staking manager return");
        assertEq(resultingBuffer, expectedBufferAfter, "resulting buffer accounts for stake");
    }
}

contract OllaCoreRebalanceInconsistentQueueTest is Test {
    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    InconsistentWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal operator;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockAccountingStakingManager();
        operator = makeAddr("operator");
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));

        withdrawalQueue = new InconsistentWithdrawalQueue();
        withdrawalQueue.initialize(address(vault), governance);

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
        vm.stopPrank();
    }

    function test_Rebalance_RevertsOnInconsistentFinalize() external {
        uint256 bufferedAmount = 5 * DECIMALS;

        asset.mint(address(vault), bufferedAmount);
        withdrawalQueue.setTotalPendingAssets(bufferedAmount);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__FinalizeInconsistent.selector, 1e18, 0));
        vm.prank(operator);
        vault.rebalance();

        assertEq(vault.accountingState().bufferedAssets, 0, "buffered assets unchanged on revert");
        assertEq(withdrawalQueue.totalPendingAssets(), bufferedAmount, "pending assets unchanged on revert");
    }
}

contract OllaCoreRebalanceMismatchQueueTest is Test {
    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    MismatchWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal operator;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockAccountingStakingManager();
        operator = makeAddr("operator");
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));

        withdrawalQueue = new MismatchWithdrawalQueue();
        withdrawalQueue.initialize(address(vault), governance);

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
        vm.stopPrank();
    }

    function test_Rebalance_RevertsOnFinalizeAmountMismatch() external {
        uint256 bufferedAmount = 5 * DECIMALS;
        uint256 queuedAmount = 2 * DECIMALS;

        asset.mint(address(vault), bufferedAmount);
        withdrawalQueue.setTotalPendingAssets(queuedAmount);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__FinalizeAmountMismatch.selector, 0, 1e18));
        vm.prank(operator);
        vault.rebalance();

        assertEq(vault.accountingState().bufferedAssets, 0, "buffered assets unchanged on revert");
        assertEq(withdrawalQueue.totalPendingAssets(), queuedAmount, "pending assets unchanged on revert");
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

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MaliciousReentrantStakingManager();
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

contract RevertingSafetyModule is ISafetyModule {
    error AccountingStale();

    address public immutable CORE_ADDRESS;
    bool internal stale;

    constructor(address coreAddress) {
        CORE_ADDRESS = coreAddress;
    }

    function setStale(bool value) external {
        stale = value;
    }

    function pause() external override { }

    function unpause() external override { }

    function isPaused() external pure override returns (bool) {
        return false;
    }

    function CORE() external view override returns (address) {
        return CORE_ADDRESS;
    }

    function checkRateDrop(uint256, uint256) external pure override { }

    function checkQueueRatio(uint256, uint256) external pure override { }

    function checkAccountingLiveness() external view override {
        if (stale) {
            revert AccountingStale();
        }
    }

    function setDepositCap(uint256) external pure override { }

    function setWithdrawalMinimum(uint256) external pure override { }

    function setMinRateDropBps(uint256) external pure override { }

    function setMaxQueueRatioBps(uint256) external pure override { }

    function setMaxAccountingDelay(uint256) external pure override { }

    function setLatestAccountingTimestamp(uint256) external pure override { }

    function checkDepositAllowed(uint256, uint256) external pure override returns (bool allowed) {
        return allowed;
    }

    function checkWithdrawalMinimum(uint256) external pure override { }
}

contract OllaCoreRebalanceAccountingLivenessTest is Test {
    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    RevertingSafetyModule internal safetyModule;
    address internal operator;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockAccountingStakingManager();
        operator = makeAddr("operator");
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation), abi.encodeCall(WithdrawalQueue.initialize, (address(vault), governance))
        );
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new RevertingSafetyModule(address(vault));

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
        vm.stopPrank();
    }

    function test_Rebalance_RevertsWhen_AccountingStale() external {
        safetyModule.setStale(true);

        vm.prank(operator);
        vm.expectRevert(RevertingSafetyModule.AccountingStale.selector);
        vault.rebalance();
    }
}

/*//////////////////////////////////////////////////////////////
                    REWARDS LIQUIDITY TESTS
//////////////////////////////////////////////////////////////*/

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";

/// @notice Staking manager that reverts on unstake when amount exceeds staked principal.
/// @dev Used to test that rebalance correctly accounts for rewards vault liquidity.
contract UnstakeRevertingStakingManager is IStakingManager {
    using SafeERC20 for IERC20;
    IERC20 public immutable STAKING_ASSET;

    uint256 public staked;
    uint256 public pending;
    uint256 public withdrawable;
    uint256 public claimable;
    uint256 public slashing;
    address public rewardsRecipient;
    uint256 private _attesterStateLastUpdated = 1;
    uint256 private _attesterStateMaxAge = type(uint256).max;

    ProviderConfig internal _providerConfig;

    constructor(IERC20 stakingAsset_) {
        STAKING_ASSET = stakingAsset_;
    }

    function setClaimableRewards(uint256 value) external {
        claimable = value;
    }

    function setSlashingDelta(uint256 value) external {
        slashing = value;
        _attesterStateLastUpdated = block.timestamp;
    }

    function setPendingUnstakes(uint256 value) external {
        pending = value;
    }

    function setWithdrawableUnstakes(uint256 value) external {
        withdrawable = value;
    }

    function setRewardsRecipient(address recipient) external {
        rewardsRecipient = recipient;
    }

    function setProviderConfig(address admin, address rewardsRecipient_) external {
        _providerConfig = ProviderConfig({ admin: admin, rewardsRecipient: rewardsRecipient_ });
    }

    function initialize(IERC20, address, address, address, address, address) external pure override { }

    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        STAKING_ASSET.safeTransferFrom(msg.sender, address(this), amount);
        staked += amount;
        return amount;
    }

    function unstake(uint256 amount) external override returns (uint256 unstakedAmount) {
        if (amount > staked) {
            revert StakingManager__InsufficientStake();
        }
        staked -= amount;
        return amount;
    }

    function setGasThreshold(uint256) external pure override { }

    function getUnstakedFunds() external pure override returns (uint256 received, bool hasRemainingExits) {
        return (0, false);
    }

    function harvestRewards() external override returns (uint256 harvested) {
        harvested = claimable;
        if (harvested > 0 && rewardsRecipient != address(0)) {
            MockAztec(address(STAKING_ASSET)).mint(rewardsRecipient, harvested);
            claimable = 0;
        }
        return harvested;
    }

    function getSlashingDelta() external view override returns (uint256 slashingDelta) {
        if (_isAttesterStateStale()) {
            revert StakingManager__AttesterStateStale(_attesterStateLastUpdated, _attesterStateMaxAge);
        }
        return slashing;
    }

    function computeAttesterState() external override returns (uint256 slashingDelta, bool completed) {
        uint256 lastUpdated = _attesterStateLastUpdated;
        bool wasStale = _isAttesterStateStale();

        _attesterStateLastUpdated = block.timestamp;
        emit AttesterStateUpdated(slashing, staked, pending, withdrawable, block.timestamp);
        if (wasStale) {
            emit AttesterStateStale(lastUpdated, _attesterStateMaxAge);
        }

        return (slashing, true);
    }

    function setAttesterStateMaxAge(uint256 maxAge) external override {
        if (maxAge == 0) {
            revert StakingManager__ZeroAmount();
        }
        _attesterStateMaxAge = maxAge;
    }

    function getClaimableRewards() external view override returns (uint256 claimableRewards) {
        return claimable;
    }

    function getAttesterStateLiveness()
        external
        view
        override
        returns (uint256 lastUpdated, uint256 maxAge, bool isStale)
    {
        lastUpdated = _attesterStateLastUpdated;
        maxAge = _attesterStateMaxAge;
        isStale = _isAttesterStateStale();
        return (lastUpdated, maxAge, isStale);
    }

    function totalStaked() external view override returns (uint256 stakedTotal) {
        return staked;
    }

    function getStakingState() external view override returns (StakingState memory state) {
        return StakingState({
            slashingDelta: slashing,
            stakedAmount: staked,
            pendingUnstakeAmount: pending,
            withdrawableAmount: withdrawable
        });
    }

    function pendingUnstakes() external view override returns (uint256 pendingUnstakeAmount) {
        return pending;
    }

    function hasExitableUnstakes() external view override returns (bool) {
        return withdrawable != 0;
    }

    function getUnstakeCursor() external pure override returns (uint256 cursor) {
        return 0;
    }

    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return _providerConfig;
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

    function _isAttesterStateStale() internal view returns (bool) {
        uint256 lastUpdated = _attesterStateLastUpdated;
        if (lastUpdated == 0) {
            return true;
        }
        return block.timestamp - lastUpdated > _attesterStateMaxAge;
    }

    function core() external pure override returns (address) {
        return address(0);
    }

    function stakingProviderRegistry() external pure override returns (IStakingProviderRegistry) {
        return IStakingProviderRegistry(address(0));
    }
}

contract OllaCoreRebalanceRewardsLiquidityTest is Test {
    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    UnstakeRevertingStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;

    address internal governance;
    address internal alice;
    address internal operator;

    function setUp() external {
        asset = new MockAztec(address(this));
        stakingManager = new UnstakeRevertingStakingManager(asset);

        governance = makeAddr("governance");
        alice = makeAddr("alice");
        operator = makeAddr("operator");

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        stAztec = new StAztec(governance, address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

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
        vm.stopPrank();
    }

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }

    function test_Rebalance_HandlesWithdrawalsBackedByRewardsVaultLiquidity() external {
        uint256 principal = 200_000 * DECIMALS;
        _performDeposit(alice, principal);

        // Stake everything so buffered liquidity is zero.
        vm.prank(operator);
        vault.rebalance();
        assertEq(vault.accountingState().bufferedAssets, 0, "buffer should be zero after stake");

        // Simulate rewards sitting in the rewards vault (counted in totalAssets via accounting).
        uint256 rewards = 69 * DECIMALS;
        asset.mint(address(rewardsVault), rewards);

        // Persist rewardsVaultBalance into accounting so exchangeRate/totalAssets includes it.
        vm.prank(operator);
        vault.updateAccounting();

        // Request redeem of all shares; assetsExpected includes rewards.
        uint256 shares = stAztec.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);

        // Rebalance should use rewards-vault funds as liquidity and avoid over-unstaking.
        // Previously this would revert with StakingManager__InsufficientStake because
        // _initiateUnstake sized against bufferedAssets only.
        vm.prank(operator);
        vault.rebalance();
    }

    function test_Rebalance_HandlesWithdrawalsBackedByClaimableRewards() external {
        uint256 principal = 200_000 * DECIMALS;
        _performDeposit(alice, principal);

        vm.prank(operator);
        vault.rebalance();
        assertEq(vault.accountingState().bufferedAssets, 0, "buffer should be zero after stake");

        // Set rewards recipient so harvest actually transfers tokens to rewards vault
        stakingManager.setRewardsRecipient(address(rewardsVault));

        // Simulate claimable rewards being included in totalAssets.
        uint256 claimableRewards = 69 * DECIMALS;
        stakingManager.setClaimableRewards(claimableRewards);
        vm.prank(operator);
        vault.updateAccounting();

        uint256 shares = stAztec.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);

        // Rebalance should not over-request unstake when withdrawals include claimable rewards.
        // The harvest step pulls the rewards into the buffer before unstake sizing.
        vm.prank(operator);
        vault.rebalance();
    }
}
