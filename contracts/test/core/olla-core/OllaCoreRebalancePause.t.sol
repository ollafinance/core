// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { StdStorage, stdStorage } from "@forge-std/StdStorage.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

contract RevertingSafetyModule is ISafetyModule {
    address public immutable CORE_ADDRESS;
    bool internal _paused;
    uint256 internal _revertAfter;
    uint256 internal _checkCount;

    constructor(address coreAddress) {
        CORE_ADDRESS = coreAddress;
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
}

contract OllaCoreRebalancePauseTest is Test {
    using stdStorage for StdStorage;
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant REBALANCE_REQUIRED_BUFFER_SLOT = 28;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal operator;
    address internal guardian;
    address internal alice;
    address internal bob;
    address internal permitOwner;
    uint256 internal permitOwnerKey;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));
        operator = makeAddr("operator");
        guardian = makeAddr("guardian");
        withdrawalQueue = new MockWithdrawalQueue();
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

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        permitOwnerKey = 0xA11CE;
        permitOwner = vm.addr(permitOwnerKey);

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        bytes32 guardianRole = vault.GUARDIAN_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vault.grantRole(guardianRole, guardian);
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

    function _signPermit(
        IERC20Permit token,
        address owner,
        uint256 ownerKey,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 nonce = token.nonces(owner);
        bytes32 digest = _buildPermitDigest(token, owner, spender, value, nonce, deadline);
        (v, r, s) = vm.sign(ownerKey, digest);
        return (v, r, s);
    }

    function _buildPermitDigest(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32 digest) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return digest;
    }

    function _findGasForPullUnstakedStop() internal returns (uint256 selectedGas) {
        uint256 snapshotId = vm.snapshotState();
        uint256[6] memory gasOptions = [uint256(120_000), 140_000, 160_000, 180_000, 200_000, 220_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success,) = address(vault).call{ gas: gasOptions[i] }(abi.encodeCall(vault.rebalance, ()));
            if (!success) {
                continue;
            }
            IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.PullUnstaked) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        vm.revertToState(snapshotId);
        assertGt(selectedGas, 0, "should find gas stipend");
    }

    function _enterPausedDoneState() internal {
        // Start a rebalance (which sets _rebalancePaused = true), then use stdstore to
        // advance progress to Done without clearing pause. This simulates a paused-at-Done
        // state that could arise from edge cases (e.g. pending + buffer at completion).
        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        assertTrue(vault.isRebalancePaused(), "pause active from partial rebalance");

        // Advance progress to Done directly, keeping pause active
        stdstore.target(address(vault)).sig("rebalanceProgress()").depth(0).enable_packed_slots()
            .checked_write(uint256(IOllaCore.RebalanceStep.Done));

        // Ensure storage layout still matches expected slot/packing
        assertEq(
            uint256(vault.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance step write mismatch"
        );

        IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance done");
        assertTrue(vault.isRebalancePaused(), "rebalance paused");
    }

    function _hasEvent(Vm.Log[] memory entries, bytes32 topic, address emitter) internal pure returns (bool) {
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == emitter && entries[i].topics[0] == topic) {
                return true;
            }
        }
        return false;
    }

    function _hasRebalancePauseUpdate(
        Vm.Log[] memory entries,
        address emitter,
        bool paused,
        IOllaCore.RebalancePauseReason reason
    ) internal pure returns (bool) {
        bytes32 topic = keccak256("RebalancePauseUpdated(bool,uint8)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != emitter || entries[i].topics[0] != topic) {
                continue;
            }
            (bool loggedPaused, uint8 loggedReason) = abi.decode(entries[i].data, (bool, uint8));
            if (loggedPaused == paused && loggedReason == uint8(reason)) {
                return true;
            }
        }
        return false;
    }

    function _deployVaultWithSafetyModule(address safetyModuleAddress)
        internal
        returns (
            OllaCore newVault,
            MockAccountingStakingManager newStakingManager,
            MockAztec newAsset,
            MockWithdrawalQueue newWithdrawalQueue,
            MockRewardsVault newRewardsVault,
            StAztec newStAztec
        )
    {
        newAsset = new MockAztec(address(this));
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        newVault = OllaCore(address(proxy));

        newStakingManager = new MockAccountingStakingManager();
        newStAztec = new StAztec(address(newVault));
        newRewardsVault = new MockRewardsVault(newAsset, address(newVault));
        newWithdrawalQueue = new MockWithdrawalQueue();
        newWithdrawalQueue.initialize(address(newVault), governance);

        newStakingManager.setRewardsToken(newAsset);
        newStakingManager.setRewardsVault(address(newRewardsVault));

        newVault.initialize(
            newAsset,
            newStAztec,
            newStakingManager,
            0,
            0,
            governance,
            address(newWithdrawalQueue),
            newRewardsVault,
            safetyModuleAddress
        );

        bytes32 operatorRole = newVault.OPERATOR_ROLE();
        vm.startPrank(governance);
        newVault.grantRole(operatorRole, operator);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         REBALANCE PAUSE FLOW
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_PauseStartsAndRecordsReason() external {
        _performDeposit(alice, 8 * DECIMALS);

        vm.recordLogs();
        _enterPausedDoneState();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertTrue(
            _hasRebalancePauseUpdate(entries, address(vault), true, IOllaCore.RebalancePauseReason.RebalanceStart),
            "pause start event"
        );
        assertEq(
            vault.rebalancePauseReason(), uint8(IOllaCore.RebalancePauseReason.RebalanceStart), "pause reason start"
        );
    }

    function test_RebalancePause_BlocksUserActionsExceptClaim() external {
        _performDeposit(alice, 10 * DECIMALS);
        _performDeposit(permitOwner, 10 * DECIMALS);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(3 * DECIMALS, bob);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        asset.mint(bob, 2 * DECIMALS);
        vm.prank(bob);
        asset.approve(address(vault), 2 * DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(bob);
        vault.deposit(2 * DECIMALS, bob);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(alice);
        vault.requestRedeem(1 * DECIMALS, alice);

        // Claims are allowed during rebalance pause
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);
        assertGt(claimed, 0, "claim should return assets");
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, claimed, "bob receives claimed assets");

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), 2 * DECIMALS, deadline
        );
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(permitOwner);
        vault.depositWithPermit(2 * DECIMALS, permitOwner, deadline, v, r, s);

        (uint8 redeemV, bytes32 redeemR, bytes32 redeemS) = _signPermit(
            IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), 1 * DECIMALS, deadline
        );
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(1 * DECIMALS, permitOwner, deadline, redeemV, redeemR, redeemS);
    }

    function test_RebalancePause_BlocksAdminAndOperatorSetters() external {
        _performDeposit(alice, 9 * DECIMALS);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        MockRewardsVault newRewardsVault = new MockRewardsVault(asset, address(vault));

        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vault.setProtocolFeeBP(1);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vault.setTreasuryFeeSplitBP(1);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vault.proposeGovernance(makeAddr("newGov"));

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vault.setRewardsVault(newRewardsVault);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vault.setTargetBufferedAssets(1);

        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(governance);
        vault.setRebalanceGasThreshold(1);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(operator);
        vault.reconcileBufferedAssets();

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(governance);
        vault.recoverStAztec(alice, 1);
    }

    function test_RebalanceCompletion_SnapshotMonotonic_WhenTargetBufferChanges() external {
        _performDeposit(alice, 12 * DECIMALS);

        vm.prank(governance);
        vault.setTargetBufferedAssets(2 * DECIMALS);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        assertTrue(vault.isRebalancePaused(), "pause active");

        uint256 snapshot = uint256(vm.load(address(vault), bytes32(REBALANCE_REQUIRED_BUFFER_SLOT)));
        assertEq(snapshot, 2 * DECIMALS, "snapshot recorded");

        stdstore.target(address(vault)).sig("targetBufferedAssets()").checked_write(7 * DECIMALS);
        uint256 snapshotAfter = uint256(vm.load(address(vault), bytes32(REBALANCE_REQUIRED_BUFFER_SLOT)));
        assertEq(snapshotAfter, snapshot, "snapshot unchanged");

        stakingManager.setActivatedAttesterCount(0);
        vm.prank(operator);
        vault.rebalance();

        assertFalse(vault.isRebalancePaused(), "pause cleared");
    }

    function test_RebalanceCompletion_SnapshotMonotonic_WhenQueueChanges() external {
        _performDeposit(alice, 20 * DECIMALS);

        uint256 shares = vault.convertToShares(4 * DECIMALS);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        assertTrue(vault.isRebalancePaused(), "pause active");

        stdstore.target(address(withdrawalQueue)).sig("totalPendingAssets()").checked_write(uint256(0));
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(1);

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance completed");
        // With the simplified completion check, pause clears even with active attesters
        // as long as the cycle reached Done with no remaining work.
        assertFalse(vault.isRebalancePaused(), "pause cleared on completion");
    }

    function test_Rebalance_CanExecuteWhileRebalancePaused() external {
        _performDeposit(alice, 7 * DECIMALS);
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(1);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        assertTrue(vault.isRebalancePaused(), "pause active");

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance completed");
        // Completion satisfaction no longer depends on attester count — pause clears.
        assertFalse(vault.isRebalancePaused(), "pause cleared on completion");
    }

    function test_Rebalance_RevertsWhenGlobalPauseActive() external {
        _performDeposit(alice, 2 * DECIMALS);
        _enterPausedDoneState();

        vm.prank(governance);
        vault.pause();

        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vm.prank(operator);
        vault.rebalance();
    }

    function test_Rebalance_PartialProgressPersistsAcrossCalls_WithGasThreshold() external {
        _performDeposit(alice, 11 * DECIMALS);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        IOllaCore.RebalanceProgress memory progressPartial = vault.rebalanceProgress();
        assertEq(uint256(progressPartial.step), uint256(IOllaCore.RebalanceStep.PullUnstaked), "partial step set");
        assertTrue(vault.isRebalancePaused(), "pause persists until completion");

        vm.prank(operator);
        vault.rebalance();

        IOllaCore.RebalanceProgress memory completed = vault.rebalanceProgress();
        assertEq(uint256(completed.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance completes");
        assertFalse(vault.isRebalancePaused(), "pause cleared");
    }

    function test_Rebalance_CompletionUnpausesAndUpdatesAccounting() external {
        uint256 depositAmount = 9 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.recordLogs();
        vm.prank(operator);
        vault.rebalance();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertTrue(
            _hasRebalancePauseUpdate(entries, address(vault), true, IOllaCore.RebalancePauseReason.RebalanceStart),
            "pause start event"
        );
        assertTrue(
            _hasRebalancePauseUpdate(entries, address(vault), false, IOllaCore.RebalancePauseReason.RebalanceComplete),
            "pause complete event"
        );

        // Rebalance completion calls _updateAccountingInternal after computeAttesterState
        // completes as part of the rebalance state machine.
        bytes32 accountingUpdated =
            keccak256("AccountingUpdated(uint256,uint256,uint256,int256,uint256,uint256,uint256,uint256)");
        assertTrue(
            _hasEvent(entries, accountingUpdated, address(vault)), "accounting update during rebalance completion"
        );

        assertFalse(vault.isRebalancePaused(), "pause cleared");
        assertEq(
            vault.rebalancePauseReason(),
            uint8(IOllaCore.RebalancePauseReason.RebalanceComplete),
            "pause reason complete"
        );

        IOllaCore.FlowCounters memory flows = vault.flowCounters();
        assertEq(flows.latestReportCumulativeDeposits, depositAmount, "accounting snapshot updated");
    }

    function test_Rebalance_PartialProgressDoesNotUpdateAccounting() external {
        _performDeposit(alice, 6 * DECIMALS);

        IOllaCore.FlowCounters memory flowsBefore = vault.flowCounters();
        uint256 reportBefore = vault.latestReport().totalAssets;

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        IOllaCore.FlowCounters memory flowsAfter = vault.flowCounters();
        assertEq(
            flowsAfter.latestReportCumulativeDeposits,
            flowsBefore.latestReportCumulativeDeposits,
            "no accounting snapshot"
        );
        assertEq(vault.latestReport().totalAssets, reportBefore, "report unchanged");
    }

    function test_Rebalance_AccountingUpdateOnlyOnCompletionCall() external {
        _performDeposit(alice, 6 * DECIMALS);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.recordLogs();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();
        Vm.Log[] memory partialLogs = vm.getRecordedLogs();

        bytes32 accountingUpdated =
            keccak256("AccountingUpdated(uint256,uint256,uint256,int256,uint256,uint256,uint256,uint256)");
        assertFalse(_hasEvent(partialLogs, accountingUpdated, address(vault)), "no accounting update on partial");

        // Complete the rebalance — accounting IS updated on the completion call
        vm.recordLogs();
        vm.prank(operator);
        vault.rebalance();
        Vm.Log[] memory completionLogs = vm.getRecordedLogs();

        assertTrue(
            _hasEvent(completionLogs, accountingUpdated, address(vault)),
            "accounting update on completion rebalance call"
        );
    }

    function test_UpdateAccounting_RevertsWhenRebalancePaused() external {
        _performDeposit(alice, 5 * DECIMALS);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(operator);
        vault.updateAccounting();
    }

    function test_UpdateAccounting_RevertsWhenProgressNotDoneEvenIfNotPaused() external {
        _performDeposit(alice, 5 * DECIMALS);

        stdstore.target(address(vault)).sig("isRebalancePaused()").enable_packed_slots().checked_write(false);
        stdstore.target(address(vault)).sig("rebalanceProgress()").depth(0).enable_packed_slots()
            .checked_write(uint256(IOllaCore.RebalanceStep.PullUnstaked));

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        vm.prank(operator);
        vault.updateAccounting();
    }

    function test_Rebalance_PausePersistsWhenAccountingUpdateReverts() external {
        RevertingSafetyModule revertingModule = new RevertingSafetyModule(address(0));
        (OllaCore revertingVault, MockAccountingStakingManager revertingStakingManager, MockAztec revertingAsset,,,) =
            _deployVaultWithSafetyModule(address(revertingModule));

        revertingAsset.mint(alice, 7 * DECIMALS);
        vm.prank(alice);
        revertingAsset.approve(address(revertingVault), 7 * DECIMALS);
        vm.prank(alice);
        revertingVault.deposit(7 * DECIMALS, alice);

        revertingStakingManager.setStakeReturnAmount(0);

        // First call: start a partial rebalance to persist _rebalancePaused = true on-chain.
        // Use low gas to stop at an intermediate step.
        uint256 gasLimit = 200_000;
        vm.prank(operator);
        (bool firstCallOk,) =
            address(revertingVault).call{ gas: gasLimit }(abi.encodeCall(revertingVault.rebalance, ()));
        firstCallOk; // silence unused variable warning

        // If the first call completed fully without partial stop, force a partial state
        if (!revertingVault.isRebalancePaused()) {
            stdstore.target(address(revertingVault)).sig("rebalanceProgress()").depth(0).enable_packed_slots()
                .checked_write(uint256(IOllaCore.RebalanceStep.ComputeAttesterState));
            stdstore.target(address(revertingVault)).sig("isRebalancePaused()").enable_packed_slots()
                .checked_write(true);
        }

        assertTrue(revertingVault.isRebalancePaused(), "pause active from partial rebalance");

        // _updateAccountingInternal is restored in the rebalance completion block.
        // The completion call hits checkAccountingLiveness at entry (1st, passes),
        // then _updateAccountingInternal calls it again (2nd, reverts).
        revertingModule.resetCheckCount();
        revertingModule.setRevertAfter(2);

        vm.expectRevert(bytes("ACCOUNTING_LIVENESS_REVERT"));
        vm.prank(operator);
        revertingVault.rebalance();

        // Rebalance reverted, so pause persists
        assertTrue(revertingVault.isRebalancePaused(), "pause persists when accounting update reverts");

        // Once the safety module recovers, rebalance completes and unpauses
        revertingModule.setRevertAfter(0);
        revertingModule.resetCheckCount();

        vm.prank(operator);
        revertingVault.rebalance();

        assertFalse(revertingVault.isRebalancePaused(), "pause cleared after successful rebalance");
    }

    /*//////////////////////////////////////////////////////////////
                    IDLE BUFFER SKIP WITH COMPUTE STEP
    //////////////////////////////////////////////////////////////*/

    function test_RebalanceIdleBufferSkip_WithComputeAttesterStateStep() external {
        // Deposit a small amount that is below staking minimum — no actual staking happens
        // (MockAccountingStakingManager returns 0 from stake when useStakeReturnAmount is set)
        _performDeposit(alice, 3 * DECIMALS);

        stakingManager.setStakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(0);

        // First rebalance — runs through all steps, nothing productive
        vm.prank(operator);
        vault.rebalance();

        // Complete rebalance if multi-step
        for (uint256 i; i < 5; ++i) {
            if (!vault.isRebalancePaused()) break;
            vm.prank(operator);
            vault.rebalance();
        }

        assertFalse(vault.isRebalancePaused(), "first rebalance should complete");
        IOllaCore.RebalanceProgress memory progress1 = vault.rebalanceProgress();
        assertEq(uint256(progress1.step), uint256(IOllaCore.RebalanceStep.Done), "first rebalance reaches Done");

        // Capture buffered assets after first (unproductive) rebalance
        IOllaCore.AccountingState memory stateAfter1 = vault.accountingState();
        uint256 bufferedAfterFirst = stateAfter1.bufferedAssets;
        assertGt(bufferedAfterFirst, 0, "should have buffered assets");

        // Second rebalance with same conditions — should skip (idle buffer guard)
        vm.prank(operator);
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) =
            vault.rebalance();

        // Verify the skip — all return values are 0 and buffered is unchanged
        assertEq(rewardsDelta, 0, "idle skip: rewardsDelta should be 0");
        assertEq(finalizedAmount, 0, "idle skip: finalizedAmount should be 0");
        assertEq(stakedAmount, 0, "idle skip: stakedAmount should be 0");
        assertEq(resultingBuffer, bufferedAfterFirst, "idle skip: buffer should be unchanged");

        // Rebalance progress should still be Done (it didn't start a new cycle)
        IOllaCore.RebalanceProgress memory progress2 = vault.rebalanceProgress();
        assertEq(uint256(progress2.step), uint256(IOllaCore.RebalanceStep.Done), "skip: still at Done step");
        assertFalse(vault.isRebalancePaused(), "skip: rebalance not paused");
    }

    /*//////////////////////////////////////////////////////////////
                       FORCE REBALANCE UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_ForceRebalanceUnpause_RevertsWhenNotAllowed() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePauseOverrideNotAllowed.selector));
        vm.prank(governance);
        vault.forceRebalanceUnpause();
    }

    function test_ForceRebalanceUnpause_RevertsWhenProgressNotDone() external {
        _performDeposit(alice, 4 * DECIMALS);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.PullUnstaked), "progress in flight");
        assertTrue(vault.isRebalancePaused(), "pause active");

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePauseOverrideNotAllowed.selector));
        vm.prank(governance);
        vault.forceRebalanceUnpause();
    }

    function test_ForceRebalanceUnpause_OnlyGuardian() external {
        _performDeposit(alice, 4 * DECIMALS);
        _enterPausedDoneState();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.GUARDIAN_ROLE()
            )
        );
        vm.prank(alice);
        vault.forceRebalanceUnpause();
    }

    function test_ForceRebalanceUnpause_EmitsGovernanceOverride() external {
        _performDeposit(alice, 4 * DECIMALS);
        _enterPausedDoneState();

        vm.recordLogs();
        vm.prank(guardian);
        vault.forceRebalanceUnpause();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertTrue(
            _hasRebalancePauseUpdate(entries, address(vault), false, IOllaCore.RebalancePauseReason.GovernanceOverride),
            "governance override event"
        );
        assertFalse(vault.isRebalancePaused(), "pause cleared");
        assertEq(
            vault.rebalancePauseReason(),
            uint8(IOllaCore.RebalancePauseReason.GovernanceOverride),
            "pause reason override"
        );
    }

    /*//////////////////////////////////////////////////////////////
                  CLAIM DURING REBALANCE PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_ClaimRequestById_SucceedsDuringRebalancePause() external {
        _performDeposit(alice, 10 * DECIMALS);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(3 * DECIMALS, bob);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();
        assertTrue(vault.isRebalancePaused(), "rebalance pause active");

        uint256 bobBalanceBefore = asset.balanceOf(bob);
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        assertGt(claimed, 0, "claim should return assets");
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, claimed, "bob receives claimed assets");
        assertEq(vault.requestOwner(requestId), address(0), "request owner cleared");
    }

    function test_ClaimRequestById_MultipleClaimsDuringRebalancePause() external {
        _performDeposit(alice, 20 * DECIMALS);

        vm.prank(alice);
        uint256 requestId1 = vault.requestRedeem(2 * DECIMALS, bob);
        vm.prank(alice);
        uint256 requestId2 = vault.requestRedeem(3 * DECIMALS, alice);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();
        assertTrue(vault.isRebalancePaused(), "rebalance pause active");

        uint256 bobBalanceBefore = asset.balanceOf(bob);
        vm.prank(alice);
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

    function test_ClaimRequestById_TransfersCorrectAssets_DuringRebalancePause() external {
        _performDeposit(alice, 10 * DECIMALS);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(3 * DECIMALS, bob);

        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        uint256 assetsExpected = request.assetsExpected;

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();
        assertTrue(vault.isRebalancePaused(), "rebalance pause active");

        uint256 vaultBalanceBefore = asset.balanceOf(address(vault));
        uint256 bobBalanceBefore = asset.balanceOf(bob);

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        assertEq(claimed, assetsExpected, "claimed matches expected assets");
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, assetsExpected, "bob receives expected assets");
        assertEq(vaultBalanceBefore - asset.balanceOf(address(vault)), assetsExpected, "vault balance decreased");
    }

    function test_ClaimRequestById_OtherOpsStillRevertDuringRebalancePause() external {
        _performDeposit(alice, 10 * DECIMALS);

        vm.prank(alice);
        vault.requestRedeem(2 * DECIMALS, bob);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();
        assertTrue(vault.isRebalancePaused(), "rebalance pause active");

        // Deposit still reverts
        asset.mint(alice, 1 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 1 * DECIMALS);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(alice);
        vault.deposit(1 * DECIMALS, alice);

        // RequestRedeem still reverts
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(alice);
        vault.requestRedeem(1 * DECIMALS, alice);

        // Instant redeem still reverts
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(alice);
        vault.redeem(1 * DECIMALS, alice);

        // UpdateAccounting still reverts
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(operator);
        vault.updateAccounting();
    }
}
