// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";

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
                               REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_HarvestsRewardsAndUpdatesCumulativeRewards() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 expectedBuffer = accountingBefore.bufferedAssets;

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
        uint256 targetBuffered = 1 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBuffered);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

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

    function test_Rebalance_FinalizeWithdrawals_BoundedGasProgresses() external {
        uint256 totalRequests = 20;
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
        uint256 bufferBefore = vault.accountingState().bufferedAssets;
        uint256 snapshotId = vm.snapshotState();

        uint256 selectedGas;
        uint256 finalizedObserved;
        uint256 bufferObserved;
        uint256[5] memory gasOptions = [uint256(400_000), 500_000, 600_000, 700_000, 800_000];

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

        assertGt(selectedGas, 0, "should find gas stipend for partial finalize");

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
        uint256 bufferAmount = 10 * DECIMALS;
        uint256 pendingAssets = 25 * DECIMALS;

        asset.mint(address(vault), bufferAmount);
        vm.prank(address(vault));
        withdrawalQueue.requestWithdrawal(alice, 1 * DECIMALS, pendingAssets, 1e18);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit UnstakeInitiated(pendingAssets - bufferAmount, pendingAssets - bufferAmount);

        vm.prank(operator);
        vault.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), pendingAssets - bufferAmount, "unstake initiated");
    }

    function test_Rebalance_Unstake_PendingDominatesTargetBufferedAssets() external {
        uint256 bufferAmount = 10 * DECIMALS;
        uint256 pendingAssets = 25 * DECIMALS;
        uint256 targetBufferedAssets = 5 * DECIMALS;

        asset.mint(address(vault), bufferAmount);

        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBufferedAssets);

        vm.prank(address(vault));
        withdrawalQueue.requestWithdrawal(alice, 1 * DECIMALS, pendingAssets, 1e18);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit UnstakeInitiated(pendingAssets - bufferAmount, pendingAssets - bufferAmount);

        vm.prank(operator);
        vault.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), pendingAssets - bufferAmount, "unstake uses pending assets");
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
        uint256 bufferAmount = 10 * DECIMALS;
        uint256 pendingAssets = 30 * DECIMALS;
        uint256 pendingUnstakes = 12 * DECIMALS;

        asset.mint(address(vault), bufferAmount);
        vm.prank(address(vault));
        withdrawalQueue.requestWithdrawal(alice, 1 * DECIMALS, pendingAssets, 1e18);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(pendingUnstakes);

        vm.expectEmit(true, true, true, true, address(vault));
        emit UnstakeInitiated(pendingAssets - bufferAmount, (pendingAssets - bufferAmount) - pendingUnstakes);

        vm.prank(operator);
        vault.rebalance();

        assertEq(
            stakingManager.lastUnstakeAmount(),
            (pendingAssets - bufferAmount) - pendingUnstakes,
            "unstake reduced by pending"
        );
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
        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(0, 0, actualStaked, expectedBufferAfter);

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

    function core() external view override returns (address) {
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
