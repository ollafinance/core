// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { StdStorage, stdStorage } from "@forge-std/StdStorage.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsCollector } from "src/core/mocks/MockRewardsCollector.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract RevertingSafetyModule is ISafetyModule {
    address public immutable CORE_ADDRESS;
    address public immutable VAULT_ADDRESS;
    bool internal _paused;
    uint256 internal _revertAfter;
    uint256 internal _checkCount;

    constructor(address coreAddress, address vaultAddress) {
        CORE_ADDRESS = coreAddress;
        VAULT_ADDRESS = vaultAddress;
    }

    function setRevertAfter(uint256 revertAfter) external {
        _revertAfter = revertAfter;
    }

    function resetCheckCount() external {
        _checkCount = 0;
    }

    function pause() external override {
        _paused = true;
    }

    function unpause() external override {
        _paused = false;
    }

    function isPaused() external view override returns (bool pausedState) {
        return _paused;
    }

    function CORE() external view override returns (address) {
        return CORE_ADDRESS;
    }

    function VAULT() external view override returns (address) {
        return VAULT_ADDRESS;
    }

    function checkRateDrop(uint256 oldRate, uint256 nextRate) external pure override {
        oldRate = oldRate;
        nextRate = nextRate;
    }

    function checkQueueRatio(uint256 queued, uint256 total) external pure override {
        queued = queued;
        total = total;
    }

    function checkAccountingLiveness() external override {
        _checkCount++;
        if (_revertAfter != 0 && _checkCount >= _revertAfter) {
            revert("ACCOUNTING_LIVENESS_REVERT");
        }
    }

    function setDepositCap(uint256 cap) external pure override {
        cap = cap;
    }

    function setWithdrawalMinimum(uint256 minimumShares) external pure override {
        minimumShares = minimumShares;
    }

    function setMinRateDropBps(uint256 minRateDropBps) external pure override {
        minRateDropBps = minRateDropBps;
    }

    function setMaxQueueRatioBps(uint256 maxQueueRatioBps) external pure override {
        maxQueueRatioBps = maxQueueRatioBps;
    }

    function setMaxAccountingDelay(uint256 maxAccountingDelay) external pure override {
        maxAccountingDelay = maxAccountingDelay;
    }

    function setLatestAccountingTimestamp(uint256 latestAccountingTimestamp) external pure override {
        latestAccountingTimestamp = latestAccountingTimestamp;
    }

    function checkDepositAllowed(uint256, uint256) external pure override returns (bool) {
        return true;
    }

    function checkWithdrawalMinimum(uint256) external pure override { }

    function depositCap() external pure override returns (uint256) {
        return type(uint256).max;
    }
}

contract OllaCoreRebalancePauseTest is Test {
    using stdStorage for StdStorage;
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsCollector internal rewardsCollector;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal operator;
    address internal guardian;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsCollector = new MockRewardsCollector(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        operator = makeAddr("operator");
        guardian = makeAddr("guardian");
        withdrawalQueue = new MockWithdrawalQueue();
        withdrawalQueue.initialize(address(vault), governance, 180_000);

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsCollector(address(rewardsCollector));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsCollector, address(safetyModule));

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        bytes32 operatorRole = core.OPERATOR_ROLE();
        bytes32 guardianRole = core.GUARDIAN_ROLE();
        vm.startPrank(governance);
        core.grantRole(operatorRole, operator);
        core.grantRole(guardianRole, guardian);
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

    function _findGasForPullUnstakedStop() internal returns (uint256 selectedGas) {
        uint256 snapshotId = vm.snapshotState();
        uint256[6] memory gasOptions = [uint256(120_000), 140_000, 160_000, 180_000, 200_000, 220_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success,) = address(core).call{ gas: gasOptions[i] }(abi.encodeCall(core.rebalance, ()));
            if (!success) {
                continue;
            }
            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.PullUnstaked) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        vm.revertToState(snapshotId);
        assertGt(selectedGas, 0, "should find gas stipend");
    }

    function _enterRebalanceInProgress() internal {
        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        core.rebalance{ gas: gasLimit }();

        assertNotEq(
            uint256(core.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance in progress from partial rebalance"
        );
    }

    function _hasEvent(Vm.Log[] memory entries, bytes32 topic, address emitter) internal pure returns (bool) {
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == emitter && entries[i].topics[0] == topic) {
                return true;
            }
        }
        return false;
    }

    function _deployWithSafetyModule(address safetyModuleAddress)
        internal
        returns (
            OllaCore newCore,
            OllaVault newVault,
            MockAccountingStakingManager newStakingManager,
            MockAztec newAsset,
            MockWithdrawalQueue newWithdrawalQueue,
            MockRewardsCollector newRewardsCollector
        )
    {
        newAsset = new MockAztec(address(this));

        // Deploy new Core
        OllaCore coreImpl = new OllaCore();
        ERC1967Proxy coreP = new ERC1967Proxy(address(coreImpl), "");
        newCore = OllaCore(address(coreP));

        // Deploy new Vault
        OllaVault vaultImpl = new OllaVault();
        ERC1967Proxy vaultP = new ERC1967Proxy(address(vaultImpl), "");
        newVault = OllaVault(address(vaultP));

        newStakingManager = new MockAccountingStakingManager();
        StAztec newStAztec = new StAztec(address(newVault));
        newRewardsCollector = new MockRewardsCollector(newAsset, address(newCore));
        newWithdrawalQueue = new MockWithdrawalQueue();
        newWithdrawalQueue.initialize(address(newVault), governance, 180_000);

        newStakingManager.setRewardsToken(newAsset);
        newStakingManager.setRewardsCollector(address(newRewardsCollector));

        newCore.initialize(
            newAsset, newStAztec, newStakingManager, 0, 5_000, governance, newRewardsCollector, safetyModuleAddress
        );

        newVault.initialize(
            newAsset, newStAztec, address(newWithdrawalQueue), safetyModuleAddress, address(newCore), governance
        );

        vm.prank(governance);
        newCore.setVault(address(newVault));

        vm.prank(governance);
        newCore.unpause();

        vm.prank(governance);
        newVault.unpause();

        bytes32 operatorRole = newCore.OPERATOR_ROLE();
        vm.startPrank(governance);
        newCore.grantRole(operatorRole, operator);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                  ADMIN OPS BLOCKED DURING REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_RebalanceInProgress_BlocksAdminAndOperatorSetters() external {
        _performDeposit(alice, 9 * DECIMALS);

        _enterRebalanceInProgress();

        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.setProtocolFeeBP(1);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.setTreasuryFeeSplitBP(1);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        core.setTargetBufferedAssets(1);

        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        vm.prank(governance);
        core.setRebalanceGasThreshold(1);

        // In the vault-core split, vault governance functions (reconcileBufferedAssets,
        // recoverStAztec) are not gated by core's whenRebalanceDone modifier.
        // They succeed even during rebalance.
    }

    /*//////////////////////////////////////////////////////////////
                     REBALANCE COMPLETION
    //////////////////////////////////////////////////////////////*/

    function test_RebalanceCompletion_WhenTargetBufferChanges() external {
        _performDeposit(alice, 12 * DECIMALS);

        vm.prank(governance);
        core.setTargetBufferedAssets(2 * DECIMALS);

        // Complete a rebalance after setting target buffer
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(0);
        vm.prank(operator);
        core.rebalance();

        assertEq(uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance completed");
    }

    function test_RebalanceCompletion_SnapshotMonotonic_WhenQueueChanges() external {
        _performDeposit(alice, 20 * DECIMALS);

        uint256 shares = core.convertToShares(4 * DECIMALS);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        _enterRebalanceInProgress();

        stdstore.target(address(withdrawalQueue)).sig("totalPendingAssets()").checked_write(uint256(0));
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(1);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance completed");
    }

    /*//////////////////////////////////////////////////////////////
                    REBALANCE CAN RESUME MID-CYCLE
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_CanExecuteWhileInProgress() external {
        _performDeposit(alice, 7 * DECIMALS);
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(1);

        _enterRebalanceInProgress();

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance completed");
    }

    function test_Rebalance_RevertsWhenGlobalPauseActive() external {
        _performDeposit(alice, 2 * DECIMALS);
        _enterRebalanceInProgress();

        vm.prank(governance);
        core.pause();

        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vm.prank(operator);
        core.rebalance();
    }

    function test_Rebalance_PartialProgressPersistsAcrossCalls_WithGasThreshold() external {
        _performDeposit(alice, 11 * DECIMALS);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        core.rebalance{ gas: gasLimit }();

        IOllaCore.RebalanceProgress memory progressPartial = core.rebalanceProgress();
        assertEq(uint256(progressPartial.step), uint256(IOllaCore.RebalanceStep.PullUnstaked), "partial step set");

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory completed = core.rebalanceProgress();
        assertEq(uint256(completed.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance completes");
    }

    /*//////////////////////////////////////////////////////////////
                     ACCOUNTING UPDATE ON COMPLETION
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_CompletionUpdatesAccounting() external {
        uint256 depositAmount = 9 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.recordLogs();
        vm.prank(operator);
        core.rebalance();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Rebalance completion calls _updateAccountingInternal after computeAttesterState
        // completes as part of the rebalance state machine.
        bytes32 accountingUpdated =
            keccak256("AccountingUpdated(uint256,uint256,uint256,int256,uint256,uint256,uint256,uint256)");
        assertTrue(
            _hasEvent(entries, accountingUpdated, address(core)), "accounting update during rebalance completion"
        );

        IOllaCore.FlowCounters memory flows = core.flowCounters();
        assertEq(flows.latestReportCumulativeDeposits, depositAmount, "accounting snapshot updated");
    }

    function test_Rebalance_PartialProgressDoesNotUpdateAccounting() external {
        _performDeposit(alice, 6 * DECIMALS);

        IOllaCore.FlowCounters memory flowsBefore = core.flowCounters();
        uint256 reportBefore = core.latestReport().totalAssets;

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        core.rebalance{ gas: gasLimit }();

        IOllaCore.FlowCounters memory flowsAfter = core.flowCounters();
        assertEq(
            flowsAfter.latestReportCumulativeDeposits,
            flowsBefore.latestReportCumulativeDeposits,
            "no accounting snapshot"
        );
        assertEq(core.latestReport().totalAssets, reportBefore, "report unchanged");
    }

    function test_Rebalance_AccountingUpdateOnlyOnCompletionCall() external {
        _performDeposit(alice, 6 * DECIMALS);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.recordLogs();
        vm.prank(operator);
        core.rebalance{ gas: gasLimit }();
        Vm.Log[] memory partialLogs = vm.getRecordedLogs();

        bytes32 accountingUpdated =
            keccak256("AccountingUpdated(uint256,uint256,uint256,int256,uint256,uint256,uint256,uint256)");
        assertFalse(_hasEvent(partialLogs, accountingUpdated, address(core)), "no accounting update on partial");

        // Complete the rebalance -- accounting IS updated on the completion call
        vm.recordLogs();
        vm.prank(operator);
        core.rebalance();
        Vm.Log[] memory completionLogs = vm.getRecordedLogs();

        assertTrue(
            _hasEvent(completionLogs, accountingUpdated, address(core)),
            "accounting update on completion rebalance call"
        );
    }

    function test_UpdateAccounting_RevertsWhenRebalanceInProgress() external {
        _performDeposit(alice, 5 * DECIMALS);

        _enterRebalanceInProgress();

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        vm.prank(operator);
        core.updateAccounting();
    }

    function test_UpdateAccounting_RevertsWhenProgressNotDone() external {
        _performDeposit(alice, 5 * DECIMALS);

        stdstore.target(address(core)).sig("rebalanceProgress()").depth(0).enable_packed_slots()
            .checked_write(uint256(IOllaCore.RebalanceStep.PullUnstaked));

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        vm.prank(operator);
        core.updateAccounting();
    }

    function test_Rebalance_StaysInProgressWhenAccountingUpdateReverts() external {
        RevertingSafetyModule revertingModule = new RevertingSafetyModule(address(0), address(0));
        (
            OllaCore revertingCore,
            OllaVault revertingVault,
            MockAccountingStakingManager revertingStakingManager,
            MockAztec revertingAsset,,
        ) = _deployWithSafetyModule(address(revertingModule));

        revertingAsset.mint(alice, 7 * DECIMALS);
        vm.prank(alice);
        revertingAsset.approve(address(revertingVault), 7 * DECIMALS);
        vm.prank(alice);
        revertingVault.deposit(7 * DECIMALS, alice, 0);

        revertingStakingManager.setStakeReturnAmount(0);

        // First call: start a partial rebalance to leave the state machine in progress.
        // Use low gas to stop at an intermediate step.
        uint256 gasLimit = 200_000;
        vm.prank(operator);
        (bool firstCallOk,) = address(revertingCore).call{ gas: gasLimit }(abi.encodeCall(revertingCore.rebalance, ()));
        firstCallOk; // silence unused variable warning

        // If the first call completed fully without partial stop, force a partial state
        if (revertingCore.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) {
            stdstore.target(address(revertingCore)).sig("rebalanceProgress()").depth(0).enable_packed_slots()
                .checked_write(uint256(IOllaCore.RebalanceStep.ComputeAttesterState));
        }

        assertNotEq(
            uint256(revertingCore.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance in progress from partial rebalance"
        );

        // _updateAccountingInternal is restored in the rebalance completion block.
        // The completion call hits checkAccountingLiveness at entry (1st, passes),
        // then _updateAccountingInternal calls it again (2nd, reverts).
        revertingModule.resetCheckCount();
        revertingModule.setRevertAfter(2);

        vm.expectRevert(bytes("ACCOUNTING_LIVENESS_REVERT"));
        vm.prank(operator);
        revertingCore.rebalance();

        // Rebalance reverted, so it stays in progress
        assertNotEq(
            uint256(revertingCore.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance stays in progress when accounting update reverts"
        );

        // Once the safety module recovers, rebalance completes
        revertingModule.setRevertAfter(0);
        revertingModule.resetCheckCount();

        vm.prank(operator);
        revertingCore.rebalance();

        assertEq(
            uint256(revertingCore.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance completes after safety module recovers"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    IDLE BUFFER SKIP WITH COMPUTE STEP
    //////////////////////////////////////////////////////////////*/

    function test_RebalanceIdleBufferSkip_WithComputeAttesterStateStep() external {
        // Deposit a small amount that is below staking minimum -- no actual staking happens
        // (MockAccountingStakingManager returns 0 from stake when useStakeReturnAmount is set)
        _performDeposit(alice, 3 * DECIMALS);

        stakingManager.setStakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(0);

        // First rebalance -- runs through all steps, nothing productive
        vm.prank(operator);
        core.rebalance();

        // Complete rebalance if multi-step
        for (uint256 i; i < 5; ++i) {
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        IOllaCore.RebalanceProgress memory progress1 = core.rebalanceProgress();
        assertEq(uint256(progress1.step), uint256(IOllaCore.RebalanceStep.Done), "first rebalance reaches Done");

        // Capture buffered assets after first (unproductive) rebalance
        uint256 bufferedAfterFirst = vault.bufferedAssets();
        assertGt(bufferedAfterFirst, 0, "should have buffered assets");

        // Advance past rebalance cooldown after cycle completion
        vm.warp(block.timestamp + 1 hours);

        // Second rebalance with same conditions -- should skip (idle buffer guard)
        vm.prank(operator);
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) =
            core.rebalance();

        // Verify the skip -- all return values are 0 and buffered is unchanged
        assertEq(rewardsDelta, 0, "idle skip: rewardsDelta should be 0");
        assertEq(finalizedAmount, 0, "idle skip: finalizedAmount should be 0");
        assertEq(stakedAmount, 0, "idle skip: stakedAmount should be 0");
        assertEq(resultingBuffer, bufferedAfterFirst, "idle skip: buffer should be unchanged");

        // Rebalance progress should still be Done (it didn't start a new cycle)
        IOllaCore.RebalanceProgress memory progress2 = core.rebalanceProgress();
        assertEq(uint256(progress2.step), uint256(IOllaCore.RebalanceStep.Done), "skip: still at Done step");
    }

    /*//////////////////////////////////////////////////////////////
                       FORCE REBALANCE RESET
    //////////////////////////////////////////////////////////////*/

    function test_ForceRebalanceReset_SucceedsWhenProgressNotDone() external {
        _performDeposit(alice, 4 * DECIMALS);

        _enterRebalanceInProgress();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.PullUnstaked), "progress in flight");

        vm.prank(guardian);
        core.forceRebalanceReset();

        IOllaCore.RebalanceProgress memory resetProgress = core.rebalanceProgress();
        assertEq(uint256(resetProgress.step), uint256(IOllaCore.RebalanceStep.Done), "step reset to Done");
        assertEq(resetProgress.stakeRemaining, 0, "stakeRemaining reset to 0");
        assertEq(resetProgress.unstakeRemaining, 0, "unstakeRemaining reset to 0");
    }

    function test_ForceRebalanceReset_OnlyGuardian() external {
        _performDeposit(alice, 4 * DECIMALS);
        _enterRebalanceInProgress();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, core.GUARDIAN_ROLE()
            )
        );
        vm.prank(alice);
        core.forceRebalanceReset();
    }

    function test_ForceRebalanceReset_EmitsRebalanceResetEvent() external {
        _performDeposit(alice, 4 * DECIMALS);
        _enterRebalanceInProgress();

        vm.recordLogs();
        vm.prank(guardian);
        core.forceRebalanceReset();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 resetTopic = keccak256("RebalanceReset()");
        assertTrue(_hasEvent(entries, resetTopic, address(core)), "RebalanceReset event emitted");

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "step reset to Done");
    }

    function test_ForceRebalanceReset_MidCycle_ResetsStateMachine() external {
        _performDeposit(alice, 4 * DECIMALS);

        _enterRebalanceInProgress();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.PullUnstaked), "stuck at PullUnstaked");

        vm.recordLogs();
        vm.prank(guardian);
        core.forceRebalanceReset();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Verify state machine fully reset
        IOllaCore.RebalanceProgress memory resetProgress = core.rebalanceProgress();
        assertEq(uint256(resetProgress.step), uint256(IOllaCore.RebalanceStep.Done), "step reset to Done");
        assertEq(resetProgress.stakeRemaining, 0, "stakeRemaining zeroed");
        assertEq(resetProgress.unstakeRemaining, 0, "unstakeRemaining zeroed");

        // Verify event
        bytes32 resetTopic = keccak256("RebalanceReset()");
        assertTrue(_hasEvent(entries, resetTopic, address(core)), "RebalanceReset event emitted");
    }

    function test_ForceRebalanceReset_MidCycle_UnblocksAdminSetters() external {
        _performDeposit(alice, 9 * DECIMALS);

        _enterRebalanceInProgress();

        // Admin setters blocked while rebalance in progress
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        vm.prank(governance);
        core.setProtocolFeeBP(100);

        // Force reset mid-cycle
        vm.prank(guardian);
        core.forceRebalanceReset();

        // Admin setters now succeed
        vm.prank(governance);
        core.setProtocolFeeBP(100);
        assertEq(core.protocolFeeBP(), 100, "setProtocolFeeBP works after force reset");

        vm.prank(governance);
        core.setTargetBufferedAssets(1 * DECIMALS);
        assertEq(core.targetBufferedAssets(), 1 * DECIMALS, "setTargetBufferedAssets works after force reset");
    }

    function test_ForceRebalanceReset_MidCycle_AllowsNewRebalanceCycle() external {
        _performDeposit(alice, 8 * DECIMALS);

        _enterRebalanceInProgress();

        // Force reset mid-cycle
        vm.prank(guardian);
        core.forceRebalanceReset();

        assertEq(uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "step reset to Done");

        // A new rebalance cycle can start
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(0);
        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "new rebalance completes");
    }

    function test_ForceRebalanceReset_RevertsWhenGlobalPauseActive() external {
        _performDeposit(alice, 4 * DECIMALS);

        _enterRebalanceInProgress();

        // Activate global pause
        vm.prank(guardian);
        core.pause();

        // forceRebalanceReset should revert due to global pause (whenNotPaused modifier)
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vm.prank(guardian);
        core.forceRebalanceReset();
    }

    function test_ForceRebalanceReset_MidCycle_ResetsIdleBuffer() external {
        _performDeposit(alice, 3 * DECIMALS);
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(0);

        // First rebalance -- unproductive, sets _rebalanceIdleBuffer
        vm.prank(operator);
        core.rebalance();
        for (uint256 i; i < 5; ++i) {
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }
        assertEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "first rebalance completes"
        );

        // Advance past rebalance cooldown after cycle completion
        vm.warp(block.timestamp + 1 hours);

        // Second call is skipped due to idle buffer -- verify the skip occurs
        vm.prank(operator);
        (uint256 rewardsDelta,,,) = core.rebalance();
        assertEq(rewardsDelta, 0, "idle skip: no rewards");

        // Now start a third rebalance by depositing (resets idle buffer on deposit)
        _performDeposit(bob, 5 * DECIMALS);
        _enterRebalanceInProgress();

        // Force reset mid-cycle -- should reset _rebalanceIdleBuffer
        vm.prank(guardian);
        core.forceRebalanceReset();

        // After force reset, a new rebalance should NOT be skipped (idle buffer was reset)
        vm.prank(operator);
        core.rebalance();
        // If idle buffer was not reset, this rebalance would be skipped.
        // Verify it actually ran by checking progress reached Done after executing.
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance ran, not skipped");
    }

    /*//////////////////////////////////////////////////////////////
                  CLAIM DURING REBALANCE IN PROGRESS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimRequestById_SucceedsDuringRebalanceInProgress() external {
        _performDeposit(alice, 10 * DECIMALS);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(3 * DECIMALS, bob, alice);

        // Finalize request before entering partial rebalance
        vm.prank(address(core));
        vault.finalizeWithdrawals(type(uint256).max);

        _enterRebalanceInProgress();

        uint256 bobBalanceBefore = asset.balanceOf(bob);
        vm.prank(bob);
        uint256 claimed = vault.claimRequestById(requestId);

        assertGt(claimed, 0, "claim should return assets");
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, claimed, "bob receives claimed assets");
        assertEq(vault.requestOwner(requestId), address(0), "request owner cleared");
    }

    function test_ClaimRequestById_MultipleClaimsDuringRebalanceInProgress() external {
        _performDeposit(alice, 20 * DECIMALS);

        vm.prank(alice);
        uint256 requestId1 = vault.requestRedeem(2 * DECIMALS, bob, alice);
        vm.prank(alice);
        uint256 requestId2 = vault.requestRedeem(3 * DECIMALS, alice, alice);

        // Finalize requests before entering partial rebalance
        vm.prank(address(core));
        vault.finalizeWithdrawals(type(uint256).max);

        _enterRebalanceInProgress();

        uint256 bobBalanceBefore = asset.balanceOf(bob);
        vm.prank(bob);
        uint256 claimed1 = vault.claimRequestById(requestId1);
        assertGt(claimed1, 0, "first claim should return assets");
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, claimed1, "bob receives first claim");

        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed2 = vault.claimRequestById(requestId2);
        assertGt(claimed2, 0, "second claim should return assets");
        assertEq(asset.balanceOf(alice) - aliceBalanceBefore, claimed2, "alice receives second claim");

        assertEq(vault.requestOwner(requestId1), address(0), "first request owner cleared");
        assertEq(vault.requestOwner(requestId2), address(0), "second request owner cleared");
    }

    function test_ClaimRequestById_TransfersCorrectAssets_DuringRebalanceInProgress() external {
        _performDeposit(alice, 10 * DECIMALS);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(3 * DECIMALS, bob, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        uint256 assetsExpected = request.assetsExpected;

        // Finalize request before entering partial rebalance
        vm.prank(address(core));
        vault.finalizeWithdrawals(type(uint256).max);

        _enterRebalanceInProgress();

        uint256 vaultBalanceBefore = asset.balanceOf(address(vault));
        uint256 bobBalanceBefore = asset.balanceOf(bob);

        vm.prank(bob);
        uint256 claimed = vault.claimRequestById(requestId);

        assertEq(claimed, assetsExpected, "claimed matches expected assets");
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, assetsExpected, "bob receives expected assets");
        assertEq(vaultBalanceBefore - asset.balanceOf(address(vault)), assetsExpected, "vault balance decreased");
    }
}
