// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { RewardsCollector } from "src/core/RewardsCollector.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { AttesterView } from "src/staking/libraries/AztecTypes.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title ComputeAttesterStateIntegration
/// @notice Targeted integration test: deposit -> rebalance -> computeAttesterState -> assert totalStaked > 0.
///         Uses vm.load to read StakingManager private storage for debugging.
contract ComputeAttesterStateIntegration is Test {
    uint256 internal constant DECIMALS = 1e18;

    // ── StakingManager storage slot constants (from `forge inspect StakingManager storageLayout`) ──
    uint256 internal constant SLOT_ATTESTERS_ARRAY = 5; // _attesters (dynamic array length)
    uint256 internal constant SLOT_ACTIVE_COUNT = 7;
    uint256 internal constant SLOT_EXITING_COUNT = 8;
    uint256 internal constant SLOT_LAST_ATTESTER_STATE_TS = 9;
    uint256 internal constant SLOT_ATTESTER_STATE_MAX_AGE = 10;
    uint256 internal constant SLOT_ATTESTER_STATE_CURSOR = 13;
    // _accumulator occupies slots 14-17 (StakingState: slashingDelta, stakedAmount, pendingUnstakeAmount, withdrawableAmount)
    uint256 internal constant SLOT_ACCUMULATOR_SLASHING = 14;
    uint256 internal constant SLOT_ACCUMULATOR_STAKED = 15;
    uint256 internal constant SLOT_ACCUMULATOR_PENDING = 16;
    uint256 internal constant SLOT_ACCUMULATOR_WITHDRAWABLE = 17;
    // _cachedState occupies slots 18-21
    uint256 internal constant SLOT_CACHED_SLASHING = 18;
    uint256 internal constant SLOT_CACHED_STAKED = 19;
    uint256 internal constant SLOT_CACHED_PENDING = 20;
    uint256 internal constant SLOT_CACHED_WITHDRAWABLE = 21;
    uint256 internal constant SLOT_GAS_THRESHOLD = 22;

    // ── Debug events ──
    event DebugAttesterArray(uint256 length);
    event DebugAttesterInfo(uint256 index, address attester, uint256 stakedAmount, uint256 status);
    event DebugCursor(uint256 attesterStateCursor);
    event DebugGasThreshold(uint256 gasThreshold);
    event DebugActiveCount(uint256 activeCount);
    event DebugAccumulator(uint256 slashing, uint256 staked, uint256 pending, uint256 withdrawable);
    event DebugCachedState(uint256 slashing, uint256 staked, uint256 pending, uint256 withdrawable);
    event DebugRollupView(address attester, uint256 effectiveBalance, uint256 status);
    event DebugComputeResult(uint256 slashingDelta, bool completed);
    event DebugTimestamps(uint256 lastUpdated, uint256 maxAge, uint256 blockTimestamp);

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;
    WithdrawalQueue internal withdrawalQueue;
    RewardsCollector internal rewardsCollector;
    SafetyModule internal safetyModule;
    MockAztecRollup internal mockRollup;
    MockAztecRollupRegistry internal mockRollupRegistry;
    address internal governance;
    address internal operator;
    address internal alice;

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy OllaCore
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        // Deploy OllaVault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));

        // Deploy WithdrawalQueue
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        withdrawalQueue.initialize(address(vault), governance, 180_000);

        // Deploy RewardsCollector
        RewardsCollector rewardsImplementation = new RewardsCollector();
        ERC1967Proxy rewardsProxy = new ERC1967Proxy(address(rewardsImplementation), "");
        rewardsCollector = RewardsCollector(address(rewardsProxy));
        rewardsCollector.initialize(IERC20(asset), address(core), governance);

        // Deploy Mock Rollup and Registry
        mockRollup = new MockAztecRollup(IERC20(asset), 0);
        mockRollupRegistry = new MockAztecRollupRegistry(address(mockRollup));

        // Deploy StakingProviderRegistry (before StakingManager)
        StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));

        // Deploy StakingManager
        StakingManager smImplementation = new StakingManager();
        ERC1967Proxy smProxy = new ERC1967Proxy(address(smImplementation), "");
        stakingManager = StakingManager(address(smProxy));

        // Initialize StakingProviderRegistry with StakingManager address
        stakingProviderRegistry.initialize(
            address(stakingManager),
            governance,
            governance, // rewardsRecipient same as admin for simplicity
            governance
        );

        // Initialize StakingManager
        stakingManager.initialize(
            IERC20(asset),
            address(mockRollupRegistry),
            address(rewardsCollector),
            address(core),
            address(stakingProviderRegistry),
            governance
        );

        // Deploy SafetyModule
        safetyModule = new SafetyModule(
            governance, governance, address(core), address(vault), 1_000_000 * DECIMALS, 500, 6_000, 1 days
        );

        // Initialize OllaCore
        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsCollector, address(safetyModule));

        // Initialize OllaVault
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        operator = makeAddr("operator");
        alice = makeAddr("alice");

        // Grant OPERATOR_ROLE on both OllaCore and StakingManager
        vm.startPrank(governance);
        core.grantRole(core.OPERATOR_ROLE(), operator);
        stakingManager.grantRole(stakingManager.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
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
    }

    uint256 internal _keyOffset;

    function _createMockKeys(uint256 count) internal returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            uint256 keyId = _keyOffset + i + 1;
            keys[i] = IStakingManager.KeyStore({
                attester: address(uint160(keyId)),
                publicKeyG1: G1Point({ x: keyId, y: keyId + 1 }),
                publicKeyG2: G2Point({ x0: keyId, x1: keyId + 1, y0: keyId + 2, y1: keyId + 3 }),
                proofOfPossession: G1Point({ x: keyId + 10, y: keyId + 11 })
            });
        }
        _keyOffset += count;
        return keys;
    }

    function _addKeys(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        vm.prank(governance);
        stakingProviderRegistry.addKeysToProvider(keys);
    }

    /// @dev Reads the _attesters array length from StakingManager storage.
    function _readAttestersLength() internal view returns (uint256) {
        return uint256(vm.load(address(stakingManager), bytes32(SLOT_ATTESTERS_ARRAY)));
    }

    /// @dev Reads AttesterInfo at a given index from the dynamic _attesters array.
    ///      Dynamic array elements start at keccak256(slot). Each AttesterInfo is 3 slots:
    ///        slot+0: address attester (packed in lower 20 bytes)
    ///        slot+1: uint256 stakedAmount
    ///        slot+2: InternalAttesterStatus (uint8, stored as uint256)
    function _readAttesterInfo(uint256 index)
        internal
        view
        returns (address attester, uint256 stakedAmount, uint256 status)
    {
        bytes32 baseSlot = keccak256(abi.encode(SLOT_ATTESTERS_ARRAY));
        uint256 elementSlot = uint256(baseSlot) + (index * 3); // 3 slots per AttesterInfo
        attester = address(uint160(uint256(vm.load(address(stakingManager), bytes32(elementSlot)))));
        stakedAmount = uint256(vm.load(address(stakingManager), bytes32(elementSlot + 1)));
        status = uint256(vm.load(address(stakingManager), bytes32(elementSlot + 2)));
    }

    function _readCursor() internal view returns (uint256) {
        return uint256(vm.load(address(stakingManager), bytes32(SLOT_ATTESTER_STATE_CURSOR)));
    }

    function _readGasThreshold() internal view returns (uint256) {
        return uint256(vm.load(address(stakingManager), bytes32(SLOT_GAS_THRESHOLD)));
    }

    function _readActiveCount() internal view returns (uint256) {
        return uint256(vm.load(address(stakingManager), bytes32(SLOT_ACTIVE_COUNT)));
    }

    function _readAccumulator() internal view returns (uint256 s, uint256 st, uint256 p, uint256 w) {
        s = uint256(vm.load(address(stakingManager), bytes32(SLOT_ACCUMULATOR_SLASHING)));
        st = uint256(vm.load(address(stakingManager), bytes32(SLOT_ACCUMULATOR_STAKED)));
        p = uint256(vm.load(address(stakingManager), bytes32(SLOT_ACCUMULATOR_PENDING)));
        w = uint256(vm.load(address(stakingManager), bytes32(SLOT_ACCUMULATOR_WITHDRAWABLE)));
    }

    function _readCachedState() internal view returns (uint256 s, uint256 st, uint256 p, uint256 w) {
        s = uint256(vm.load(address(stakingManager), bytes32(SLOT_CACHED_SLASHING)));
        st = uint256(vm.load(address(stakingManager), bytes32(SLOT_CACHED_STAKED)));
        p = uint256(vm.load(address(stakingManager), bytes32(SLOT_CACHED_PENDING)));
        w = uint256(vm.load(address(stakingManager), bytes32(SLOT_CACHED_WITHDRAWABLE)));
    }

    function _readTimestamps() internal view returns (uint256 lastUpdated, uint256 maxAge) {
        lastUpdated = uint256(vm.load(address(stakingManager), bytes32(SLOT_LAST_ATTESTER_STATE_TS)));
        maxAge = uint256(vm.load(address(stakingManager), bytes32(SLOT_ATTESTER_STATE_MAX_AGE)));
    }

    /// @dev Emits all StakingManager internal debug state.
    function _emitFullDebugState(string memory phase) internal {
        emit log_string(string.concat("=== DEBUG: ", phase, " ==="));

        // Attester array
        uint256 length = _readAttestersLength();
        emit DebugAttesterArray(length);
        for (uint256 i; i < length; ++i) {
            (address attester, uint256 stakedAmount, uint256 status) = _readAttesterInfo(i);
            emit DebugAttesterInfo(i, attester, stakedAmount, status);

            // Also query the rollup view for this attester
            AttesterView memory view_ = mockRollup.getAttesterView(attester);
            emit DebugRollupView(attester, view_.effectiveBalance, uint256(view_.status));
        }

        // Cursor
        emit DebugCursor(_readCursor());

        // Gas threshold
        emit DebugGasThreshold(_readGasThreshold());

        // Active count
        emit DebugActiveCount(_readActiveCount());

        // Accumulator
        {
            (uint256 s, uint256 st, uint256 p, uint256 w) = _readAccumulator();
            emit DebugAccumulator(s, st, p, w);
        }

        // Cached state
        {
            (uint256 s, uint256 st, uint256 p, uint256 w) = _readCachedState();
            emit DebugCachedState(s, st, p, w);
        }

        // Timestamps
        {
            (uint256 lastUpdated, uint256 maxAge) = _readTimestamps();
            emit DebugTimestamps(lastUpdated, maxAge, block.timestamp);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS (EVENT)
    //////////////////////////////////////////////////////////////*/

    function _hasEvent(Vm.Log[] memory entries, bytes32 topic, address emitter) internal pure returns (bool) {
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == emitter && entries[i].topics[0] == topic) {
                return true;
            }
        }
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Core test: deposit -> rebalance -> computeAttesterState -> totalStaked > 0
    function test_computeAttesterState_reflectsStakedAmount() external {
        // ── Setup ──
        uint256 activationThreshold = 200_000 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(5);

        uint256 depositAmount = 200_006 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // ── Debug: state before rebalance ──
        _emitFullDebugState("BEFORE REBALANCE");

        // ── Step 1: Rebalance (stakes funds on rollup) ──
        vm.prank(operator);
        core.rebalance();

        IOllaCore.AccountingState memory stateAfterRebalance1 = core.accountingState();
        emit log_named_uint("bufferedAssets after rebalance 1", vault.bufferedAssets());
        emit log_named_uint("stakedPrincipal after rebalance 1", stateAfterRebalance1.stakedPrincipal);

        // If rebalance is still in progress, call again
        if (core.rebalanceProgress().step != IOllaCore.RebalanceStep.Done) {
            vm.prank(operator);
            core.rebalance();
        }

        // ── Debug: state after rebalance ──
        _emitFullDebugState("AFTER REBALANCE");

        IOllaCore.AccountingState memory stateAfterRebalance = core.accountingState();
        emit log_named_uint("bufferedAssets after rebalance", vault.bufferedAssets());
        emit log_named_uint("stakedPrincipal after rebalance", stateAfterRebalance.stakedPrincipal);

        // Verify funds are actually on the rollup
        uint256 attesterCount = _readAttestersLength();
        assertGt(attesterCount, 0, "Should have at least one attester registered");

        for (uint256 i; i < attesterCount; ++i) {
            (address attester,,) = _readAttesterInfo(i);
            uint256 rollupStake = mockRollup.stakes(attester);
            emit log_named_address("attester", attester);
            emit log_named_uint("rollup stake", rollupStake);
            assertGt(rollupStake, 0, "Attester should have stake on rollup");
        }

        // ── Step 2: computeAttesterState ──
        emit log_string("=== Calling computeAttesterState ===");

        vm.prank(operator);
        (uint256 slashingDelta, bool completed) = stakingManager.computeAttesterState();
        emit DebugComputeResult(slashingDelta, completed);

        assertTrue(completed, "computeAttesterState should complete in one pass");

        // ── Debug: state after computeAttesterState ──
        _emitFullDebugState("AFTER computeAttesterState");

        // ── Key assertion: totalStaked must reflect the staked amount ──
        uint256 totalStaked = stakingManager.totalStaked();
        emit log_named_uint("totalStaked from StakingManager", totalStaked);

        assertGt(totalStaked, 0, "totalStaked must be > 0 after staking + computeAttesterState");
        assertEq(totalStaked, activationThreshold, "totalStaked should equal activation threshold (1 attester)");
    }

    /// @notice Isolates computeAttesterState by checking each step of the accumulator loop.
    function test_computeAttesterState_accumulatorDebug() external {
        // ── Setup: stake one attester directly through StakingManager ──
        uint256 activationThreshold = 100 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(1);

        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // ── Rebalance to stake ──
        vm.prank(operator);
        core.rebalance();

        // Complete rebalance if multi-step
        for (uint256 i; i < 5; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        // ── Verify attester is registered and active ──
        uint256 length = _readAttestersLength();
        emit log_named_uint("_attesters.length", length);
        assertEq(length, 1, "Should have exactly 1 attester");

        (address attester, uint256 stakedAmt, uint256 status) = _readAttesterInfo(0);
        emit log_named_address("attester[0].attester", attester);
        emit log_named_uint("attester[0].stakedAmount", stakedAmt);
        emit log_named_uint("attester[0].status (0=Inactive,1=Active,2=Exiting)", status);
        assertEq(status, 1, "Attester should be Active (1)");
        assertEq(stakedAmt, activationThreshold, "stakedAmount should match activation threshold");

        // ── Verify rollup view ──
        AttesterView memory view_ = mockRollup.getAttesterView(attester);
        emit log_named_uint("rollup effectiveBalance", view_.effectiveBalance);
        emit log_named_uint("rollup status (3=VALIDATING)", uint256(view_.status));
        assertGt(view_.effectiveBalance, 0, "Rollup should report positive effectiveBalance");

        // ── Check cursor and gas threshold before compute ──
        uint256 cursor = _readCursor();
        uint256 gasThresh = _readGasThreshold();
        emit log_named_uint("cursor before compute", cursor);
        emit log_named_uint("gasThreshold", gasThresh);
        assertEq(cursor, 0, "Cursor should be 0 before first compute");

        // ── Call computeAttesterState ──
        vm.prank(operator);
        (uint256 slashingDelta, bool completed) = stakingManager.computeAttesterState();

        emit log_named_uint("slashingDelta", slashingDelta);
        emit log_named_uint("completed (1=true)", completed ? 1 : 0);
        assertTrue(completed, "Should complete in one pass with 1 attester");

        // ── Check accumulator and cached state after ──
        {
            (uint256 accSlash, uint256 accStaked, uint256 accPending, uint256 accWithdrawable) = _readAccumulator();
            emit log_named_uint("accumulator.stakedAmount", accStaked);
            assertEq(accStaked, activationThreshold, "Accumulator stakedAmount should match");
        }

        {
            (uint256 cacSlash, uint256 cacStaked, uint256 cacPending, uint256 cacWithdrawable) = _readCachedState();
            emit log_named_uint("cachedState.stakedAmount", cacStaked);
            assertEq(cacStaked, activationThreshold, "Cached stakedAmount should match");
        }

        // ── Final: totalStaked should be > 0 ──
        uint256 totalStaked = stakingManager.totalStaked();
        emit log_named_uint("totalStaked()", totalStaked);
        assertEq(totalStaked, activationThreshold, "totalStaked must equal activation threshold");
    }

    /// @notice Tests that the full flow (deposit -> rebalance) results in
    ///         OllaCore.stakedPrincipal reflecting the staked amount, because rebalance
    ///         now integrates computeAttesterState and _updateAccountingInternal.
    function test_fullFlow_stakedPrincipalUpdatedAfterRebalance() external {
        uint256 activationThreshold = 200_000 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(3); // extra key so remainder doesn't cause InsufficientKeys

        uint256 depositAmount = 400_000 * DECIMALS; // exactly 2 attesters worth
        _performDeposit(alice, depositAmount);

        // ── Rebalance to stake (now includes computeAttesterState + updateAccounting) ──
        vm.prank(operator);
        core.rebalance();

        // Complete rebalance if multi-step
        for (uint256 i; i < 10; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        assertEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete"
        );

        // ── Verify totalStaked on StakingManager is correct ──
        uint256 totalStaked = stakingManager.totalStaked();
        emit log_named_uint("totalStaked after rebalance", totalStaked);
        assertEq(totalStaked, activationThreshold * 2, "totalStaked should be 2x activation threshold");

        // ── Verify OllaCore.stakedPrincipal is synced via accounting ──
        IOllaCore.AccountingState memory statePostRebalance = core.accountingState();
        emit log_named_uint("stakedPrincipal after rebalance", statePostRebalance.stakedPrincipal);
        assertEq(
            statePostRebalance.stakedPrincipal,
            activationThreshold * 2,
            "OllaCore stakedPrincipal must match totalStaked after rebalance"
        );
    }

    /// @notice Tests multi-attester scenario to ensure the loop processes all attesters.
    function test_computeAttesterState_multipleAttesters() external {
        uint256 activationThreshold = 50 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 numAttesters = 5;
        _addKeys(numAttesters);

        uint256 depositAmount = activationThreshold * numAttesters;
        _performDeposit(alice, depositAmount);

        // Rebalance to stake all
        vm.prank(operator);
        core.rebalance();

        for (uint256 i; i < 10; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        // Verify all attesters registered
        uint256 length = _readAttestersLength();
        emit log_named_uint("attester count", length);
        assertEq(length, numAttesters, "Should have all attesters registered");

        // Dump all attester states
        for (uint256 i; i < length; ++i) {
            (address att, uint256 amt, uint256 sts) = _readAttesterInfo(i);
            emit DebugAttesterInfo(i, att, amt, sts);
            assertEq(sts, 1, "All attesters should be Active");
            assertEq(amt, activationThreshold, "All attesters should have correct stakedAmount");
        }

        // computeAttesterState
        vm.prank(operator);
        (uint256 slashingDelta, bool completed) = stakingManager.computeAttesterState();
        assertTrue(completed, "Should complete in one pass");

        uint256 totalStaked = stakingManager.totalStaked();
        emit log_named_uint("totalStaked", totalStaked);
        assertEq(totalStaked, activationThreshold * numAttesters, "totalStaked should be sum of all attester stakes");
    }

    /*//////////////////////////////////////////////////////////////
                    G-1: MULTI-CALL COMPUTE WITHIN REBALANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys 12 attesters with a high gasThreshold so computeAttesterState processes
    ///         only ~1-2 attesters per call.  Verifies multi-pass rebalance resume and final accounting.
    function test_multiCallComputeAttesterState_withinRebalance() external {
        uint256 activationThreshold = 100 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 numAttesters = 12;
        _addKeys(numAttesters);

        uint256 depositAmount = activationThreshold * numAttesters;
        _performDeposit(alice, depositAmount);

        // Set a high gasThreshold on StakingManager so the accumulation loop
        // can only process ~1-2 attesters per call.
        vm.prank(address(core));
        stakingManager.setGasThreshold(400_000);

        // ── First rebalance call: should stake and enter ComputeAttesterState ──
        vm.prank(operator);
        core.rebalance();

        // Continue calling until paused at ComputeAttesterState (or until rebalance completes)
        uint256 maxCalls = 30;
        uint256 callsMade = 1;
        uint256 pausedAtComputeCount;
        for (uint256 i; i < maxCalls; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.ComputeAttesterState) {
                pausedAtComputeCount++;
            }
            vm.prank(operator);
            core.rebalance();
            callsMade++;
        }

        // Verify rebalance completed
        assertEq(
            uint256(core.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should complete after multi-pass compute"
        );
        IOllaCore.RebalanceProgress memory finalProgress = core.rebalanceProgress();
        assertEq(uint256(finalProgress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should reach Done step");

        // Verify stakedPrincipal matches actual staked amount
        IOllaCore.AccountingState memory stateAfter = core.accountingState();
        assertEq(
            stateAfter.stakedPrincipal,
            activationThreshold * numAttesters,
            "stakedPrincipal must match total staked amount"
        );

        // Verify totalStaked on StakingManager is correct
        uint256 totalStaked = stakingManager.totalStaked();
        assertEq(totalStaked, activationThreshold * numAttesters, "StakingManager totalStaked must match");
    }

    /// @notice Same as above but verifies AccountingUpdated is emitted on the completion call.
    function test_multiCallComputeAttesterState_emitsAccountingUpdated() external {
        uint256 activationThreshold = 100 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 numAttesters = 10;
        _addKeys(numAttesters);

        uint256 depositAmount = activationThreshold * numAttesters;
        _performDeposit(alice, depositAmount);

        vm.prank(address(core));
        stakingManager.setGasThreshold(400_000);

        // Run rebalance, recording logs on every call (including the first)
        uint256 maxCalls = 30;
        bool emittedAccounting;
        bytes32 accountingUpdatedTopic =
            keccak256("AccountingUpdated(uint256,uint256,uint256,int256,uint256,uint256,uint256,uint256)");

        for (uint256 i; i < maxCalls; ++i) {
            vm.recordLogs();
            vm.prank(operator);
            core.rebalance();
            Vm.Log[] memory entries = vm.getRecordedLogs();

            if (_hasEvent(entries, accountingUpdatedTopic, address(core))) {
                emittedAccounting = true;
            }

            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
        }

        assertEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete"
        );
        assertTrue(emittedAccounting, "AccountingUpdated event must be emitted on the completion call");
    }

    /*//////////////////////////////////////////////////////////////
              G-3: GAS THRESHOLD MISCONFIGURATION STALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets an extremely high gasThreshold after staking, causing computeAttesterState
    ///         to never satisfy the gas check inside its loop during rebalance.
    ///         Documents the stall behavior.
    function test_gasThresholdMisconfiguration_stallsComputeAttesterState() external {
        uint256 activationThreshold = 100 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        // Add enough keys for two batches so we can complete one rebalance and start another
        _addKeys(3);

        // Phase 1: Deposit and rebalance normally to stake 1 attester
        uint256 depositAmount = activationThreshold;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        core.rebalance();

        for (uint256 i; i < 10; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        assertEq(
            uint256(core.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "first rebalance should complete"
        );
        assertGt(_readAttestersLength(), 0, "should have at least 1 attester");

        // Phase 2: Set extremely high gasThreshold so computeAttesterState loop
        // never processes any attester.
        vm.prank(address(core));
        stakingManager.setGasThreshold(10_000_000);

        // New deposit to clear idle buffer guard and trigger a new rebalance cycle
        _performDeposit(alice, activationThreshold);

        // Advance past rebalance cooldown so a new cycle can start
        vm.warp(block.timestamp + 1 hours);

        // Call rebalance repeatedly with limited gas. The staking step will also be affected
        // by the high threshold (no new staking), but that's fine -- the key point is that
        // ComputeAttesterState cannot complete.
        uint256 stallCount;
        for (uint256 i; i < 10; ++i) {
            vm.prank(operator);
            core.rebalance{ gas: 5_000_000 }();

            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.ComputeAttesterState) {
                stallCount++;
            }

            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
        }

        // The rebalance should still be paused (stalled at ComputeAttesterState)
        assertNotEq(
            uint256(core.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should remain in progress (stalled)"
        );

        IOllaCore.RebalanceProgress memory finalProgress = core.rebalanceProgress();
        assertEq(
            uint256(finalProgress.step),
            uint256(IOllaCore.RebalanceStep.ComputeAttesterState),
            "step should be stuck at ComputeAttesterState"
        );

        assertGt(stallCount, 0, "should have stalled at ComputeAttesterState at least once");
    }

    /*//////////////////////////////////////////////////////////////
           G-4: EMPTY ATTESTER ARRAY DURING REBALANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits funds below the activation threshold so _stake returns 0 (no attesters created).
    ///         StakeSurplus step produces 0 staked, ComputeAttesterState completes immediately.
    function test_emptyAttesterArray_computeAttesterStateCompletesImmediately() external {
        uint256 activationThreshold = 100 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        // Add keys (so _stake won't revert with InsufficientKeys), but deposit less
        // than the activation threshold -- _calculateAttestersToStake returns 0 -> _stake returns 0.
        _addKeys(1);

        uint256 depositAmount = 50 * DECIMALS; // below 100 ether threshold
        _performDeposit(alice, depositAmount);

        // StakeSurplus: stakeRemaining = 50, but _stake returns 0 (amount < threshold)
        // -> advances to ComputeAttesterState with empty attester array
        vm.prank(operator);
        core.rebalance();

        // With no attesters, computeAttesterState completes immediately (empty array -> progressed=true)
        // So rebalance should reach Done
        for (uint256 i; i < 5; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        // Verify rebalance completed and pause is cleared
        assertEq(
            uint256(core.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should complete with empty attester array"
        );
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should reach Done");

        // Verify the attester array is indeed empty
        uint256 length = _readAttestersLength();
        assertEq(length, 0, "attester array should be empty");

        // Verify accounting state -- nothing staked, everything buffered
        IOllaCore.AccountingState memory state = core.accountingState();
        assertEq(state.stakedPrincipal, 0, "stakedPrincipal should be 0 with no attesters");
        assertEq(vault.bufferedAssets(), depositAmount, "all assets should remain buffered");
    }

    /*//////////////////////////////////////////////////////////////
        G-5: STANDALONE updateAccounting() AFTER REBALANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Completes a full rebalance cycle, then calls computeAttesterState + updateAccounting
    ///         to verify the steady-state refresh path still works.
    function test_standaloneUpdateAccounting_afterRebalance() external {
        uint256 activationThreshold = 100 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(2);

        uint256 depositAmount = activationThreshold * 2;
        _performDeposit(alice, depositAmount);

        // Complete full rebalance cycle
        vm.prank(operator);
        core.rebalance();

        for (uint256 i; i < 10; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        assertEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete"
        );

        // Verify stakedPrincipal after rebalance
        IOllaCore.AccountingState memory stateAfterRebalance = core.accountingState();
        assertEq(
            stateAfterRebalance.stakedPrincipal, activationThreshold * 2, "stakedPrincipal should match after rebalance"
        );

        // Simulate time passing, then refresh cache via standalone computeAttesterState
        vm.warp(block.timestamp + 1 hours);

        vm.prank(operator);
        (uint256 slashingDelta, bool completed) = stakingManager.computeAttesterState();
        assertTrue(completed, "standalone computeAttesterState should complete");
        assertEq(slashingDelta, 0, "no slashing should have occurred");

        // Call updateAccounting as operator -- verify it succeeds
        vm.prank(operator);
        core.updateAccounting();

        // Verify stakedPrincipal is still correct
        IOllaCore.AccountingState memory stateAfterAccounting = core.accountingState();
        assertEq(
            stateAfterAccounting.stakedPrincipal,
            activationThreshold * 2,
            "stakedPrincipal should be correct after standalone updateAccounting"
        );
    }

    /*//////////////////////////////////////////////////////////////
          G-6: _hasGasForStep() VS INTERNAL GAS THRESHOLD
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that when _hasGasForStep passes but computeAttesterState internally
    ///         cannot progress (due to its own gas threshold), progress is saved correctly
    ///         without corruption.
    function test_hasGasForStep_passesButInternalGasThresholdStops() external {
        uint256 activationThreshold = 100 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(5);

        uint256 depositAmount = activationThreshold * 5;
        _performDeposit(alice, depositAmount);

        // Set StakingManager gas threshold high enough that the internal loop breaks early
        // but low enough that _hasGasForStep() in OllaCore still passes
        vm.prank(address(core));
        stakingManager.setGasThreshold(300_000);

        // Run rebalance
        vm.prank(operator);
        core.rebalance();

        // Keep calling, checking that step saves progress correctly
        uint256 computeCallCount;
        for (uint256 i; i < 15; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.ComputeAttesterState) {
                computeCallCount++;
            }
            vm.prank(operator);
            core.rebalance();
        }

        // Verify rebalance eventually completes
        assertEq(
            uint256(core.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should eventually complete"
        );

        // Verify no data corruption -- stakedPrincipal and totalStaked should match
        IOllaCore.AccountingState memory state = core.accountingState();
        uint256 totalStaked = stakingManager.totalStaked();
        assertEq(state.stakedPrincipal, totalStaked, "stakedPrincipal must match StakingManager totalStaked");
        assertEq(totalStaked, activationThreshold * 5, "totalStaked should equal all 5 attesters");
    }

    /*//////////////////////////////////////////////////////////////
               EXISTING TESTS (PRESERVED)
    //////////////////////////////////////////////////////////////*/

    /// @notice Demonstrates that too-low gas on a standalone computeAttesterState call
    ///         does not corrupt the existing cached state (populated by rebalance).
    function test_computeAttesterState_lowGasDoesNotCorruptCache() external {
        uint256 activationThreshold = 100 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(1);

        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Rebalance now includes computeAttesterState, so cache is populated after rebalance
        vm.prank(operator);
        core.rebalance();

        for (uint256 i; i < 5; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        uint256 length = _readAttestersLength();
        assertEq(length, 1, "Should have exactly 1 attester");

        // Cache should already be populated from rebalance
        (uint256 cachedSlashPre, uint256 cachedStakedPre,,) = _readCachedState();
        assertEq(cachedStakedPre, activationThreshold, "cached stakedAmount should be set by rebalance");

        emit log_string("=== computeAttesterState with low gas ===");
        bytes memory payload = abi.encodeWithSelector(stakingManager.computeAttesterState.selector);
        vm.prank(operator);
        (bool okLow, bytes memory retLow) = address(stakingManager).call{ gas: 70_000 }(payload);
        assertTrue(okLow, "low-gas computeAttesterState should not revert");
        if (retLow.length == 64) {
            (uint256 slashingDelta, bool completed) = abi.decode(retLow, (uint256, bool));
            emit DebugComputeResult(slashingDelta, completed);
            // The low-gas call should NOT report completed (progressed boolean check)
            assertFalse(completed, "low-gas call should not complete");
        }

        // The existing cache should NOT be corrupted by the low-gas call
        (uint256 cachedSlashLow, uint256 cachedStakedLow,,) = _readCachedState();
        emit DebugCachedState(cachedSlashLow, cachedStakedLow, 0, 0);
        assertEq(cachedStakedLow, activationThreshold, "cached stakedAmount should be preserved after low-gas call");

        emit log_string("=== computeAttesterState with sufficient gas ===");
        vm.prank(operator);
        (uint256 slashingDeltaOk, bool completedOk) = stakingManager.computeAttesterState();
        emit DebugComputeResult(slashingDeltaOk, completedOk);
        assertTrue(completedOk, "computeAttesterState should complete with sufficient gas");

        uint256 totalStaked = stakingManager.totalStaked();
        emit log_named_uint("totalStaked", totalStaked);
        assertEq(totalStaked, activationThreshold, "totalStaked should match activation threshold");
    }
}
