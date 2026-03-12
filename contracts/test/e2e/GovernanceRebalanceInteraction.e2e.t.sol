// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

/// @title GovernanceRebalanceInteractionE2ETest
/// @notice Phase 1 E2E: validates governance parameter changes during/between rebalance cycles.
///         Wires real OllaGovernance (timelock), OllaCore, OllaVault, WithdrawalQueue, SafetyModule
///         with MockAccountingStakingManager and MockRewardsAccumulator.
contract GovernanceRebalanceInteractionE2ETest is Test {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OllaProtocolFeesPaid(uint256 protocolFeeAssets, uint256 treasuryShares, uint256 providerShares);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MIN_DELAY = 1 days;
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant PROTOCOL_FEE_BP = 500;
    uint256 internal constant TREASURY_FEE_SPLIT_BP = 5_000;
    uint256 internal constant BP_DIVISOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                             TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    OllaGovernance internal gov;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    WithdrawalQueue internal withdrawalQueue;
    SafetyModule internal safetyModule;
    MockAccountingStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockAztec internal asset;

    address internal admin;
    address internal guardian;
    address internal operator;
    address internal alice;
    address internal treasury;
    address internal providerRewards;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        treasury = makeAddr("treasury");
        providerRewards = makeAddr("providerRewards");

        asset = new MockAztec(address(this));

        // ---- Deploy OllaGovernance (impl + proxy + init) ----
        OllaGovernance govImpl = new OllaGovernance();
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(OllaGovernance.initialize, (MIN_DELAY, proposers, executors, admin, treasury))
        );
        gov = OllaGovernance(payable(address(govProxy)));

        // ---- Deploy OllaCore (impl + proxy) ----
        OllaCore coreImpl = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), "");
        core = OllaCore(address(coreProxy));

        // ---- Deploy OllaVault (impl + proxy) ----
        OllaVault vaultImpl = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        vault = OllaVault(address(vaultProxy));

        // ---- Deploy satellite contracts ----
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new SafetyModule(
            admin,
            guardian,
            address(core),
            address(vault),
            1_000_000 * DECIMALS, // depositCap
            500, // minRateDropBps (5%)
            6_000, // maxQueueRatioBps (60%)
            7 days // maxAccountingDelay — generous to avoid liveness triggers during governance warps
        );

        // ---- Deploy WithdrawalQueue (proxy) ----
        WithdrawalQueue queueImpl = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImpl), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        withdrawalQueue.initialize(address(vault), address(gov), 180_000);

        // ---- Configure mock staking manager ----
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));
        stakingManager.setUnstakedToken(asset);
        stakingManager.setProviderRewardsRecipient(providerRewards);

        // ---- Initialize OllaCore with OllaGovernance as owner ----
        core.initialize(
            asset,
            stAztec,
            stakingManager,
            PROTOCOL_FEE_BP,
            TREASURY_FEE_SPLIT_BP,
            address(gov),
            rewardsAccumulator,
            address(safetyModule)
        );

        // ---- Initialize OllaVault ----
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), address(gov));

        // ---- Wire contracts ----
        vm.prank(address(gov));
        core.setVault(address(vault));
        vm.prank(admin);
        gov.setCore(address(core));

        // ---- Unpause ----
        vm.prank(address(gov));
        core.unpause();
        vm.prank(address(gov));
        vault.unpause();

        // ---- Advance past rebalance cooldown ----
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address depositor, uint256 amount) internal returns (uint256 shares) {
        asset.mint(depositor, amount);
        vm.prank(depositor);
        asset.approve(address(vault), amount);
        vm.prank(depositor);
        shares = vault.deposit(amount, depositor, 0);
    }

    function _scheduleAndExecute(address target, bytes memory data) internal {
        _scheduleAndExecute(target, data, bytes32(0));
    }

    function _scheduleAndExecute(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(admin);
        gov.schedule(target, 0, data, bytes32(0), salt, MIN_DELAY);
        // Read the ready timestamp from timelock storage instead of using block.timestamp,
        // because via_ir optimizer may cache TIMESTAMP across vm.warp cheatcode calls.
        bytes32 id = gov.hashOperation(target, 0, data, bytes32(0), salt);
        vm.warp(gov.getTimestamp(id));
        vm.prank(admin);
        gov.execute(target, 0, data, bytes32(0), salt);
    }

    function _fullRebalance() internal returns (uint256, uint256, uint256, uint256) {
        vm.prank(operator);
        return core.rebalance();
    }

    function _warpPastCooldown() internal {
        vm.warp(block.timestamp + 1 hours + 1);
    }

    /*//////////////////////////////////////////////////////////////
              TEST 1A: GOVERNANCE BLOCKED DURING REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_GovernanceCannotChangeFeeDuringRebalance() external {
        // --- Setup: deposit and force rebalance to stop mid-cycle ---
        _performDeposit(alice, 100 * DECIMALS);

        // Make getUnstakedFunds return hasRemainingExits=true to stall at PullUnstaked
        stakingManager.setWithdrawableUnstakes(1);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _fullRebalance();

        // Verify precondition: rebalance stuck mid-cycle
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertTrue(progress.step != IOllaCore.RebalanceStep.Done, "rebalance should be stuck mid-cycle");

        // --- Schedule governance action ---
        bytes memory data = abi.encodeCall(IOllaGovernance.setProtocolFeeBP, (1_000));
        vm.prank(admin);
        gov.schedule(address(gov), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        // --- Execute should revert because whenRebalanceDone guard blocks it ---
        vm.expectRevert(IOllaCore.OllaCore__RebalanceInProgress.selector);
        vm.prank(admin);
        gov.execute(address(gov), 0, data, bytes32(0), bytes32(0));

        // --- protocolFeeBP unchanged ---
        assertEq(core.protocolFeeBP(), PROTOCOL_FEE_BP, "fee should remain unchanged");
    }

    /*//////////////////////////////////////////////////////////////
         TEST 1B: GOVERNANCE FEE CHANGE BETWEEN REBALANCE CYCLES
    //////////////////////////////////////////////////////////////*/

    function test_GovernanceCanChangeFeeBetweenRebalanceCycles() external {
        // --- Setup: deposit, keep all buffered, complete first rebalance ---
        _performDeposit(alice, 100 * DECIMALS);

        // High target buffer so nothing gets staked
        vm.prank(address(gov));
        core.setTargetBufferedAssets(1_000 * DECIMALS);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _fullRebalance();

        // First rebalance establishes baseline accounting. Verify it completed.
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "first rebalance should complete");

        // --- Change protocolFeeBP from 500 to 1000 via governance ---
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.setProtocolFeeBP, (1_000)));
        assertEq(core.protocolFeeBP(), 1_000, "protocol fee should be 1000 bp");

        // --- Simulate 10e18 rewards and rebalance ---
        stakingManager.setHarvestedRewards(10 * DECIMALS);
        // Signal claimable rewards so the idle-buffer optimisation doesn't skip the cycle
        stakingManager.setClaimableRewards(1);

        _warpPastCooldown();

        vm.recordLogs();
        _fullRebalance();

        // --- Verify OllaProtocolFeesPaid event ---
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 feeTopic = OllaProtocolFeesPaid.selector;
        bool feeEventFound;
        uint256 eventFeeAssets;
        uint256 eventTreasuryShares;
        uint256 eventProviderShares;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(core) && entries[i].topics[0] == feeTopic) {
                (eventFeeAssets, eventTreasuryShares, eventProviderShares) =
                    abi.decode(entries[i].data, (uint256, uint256, uint256));
                feeEventFound = true;
                break;
            }
        }
        assertTrue(feeEventFound, "OllaProtocolFeesPaid should be emitted");

        // 10e18 rewards * 10% fee = 1e18 in fee assets
        assertEq(eventFeeAssets, 1 * DECIMALS, "protocol fee assets should be 1e18");

        // Treasury and provider should have received shares
        assertGt(stAztec.balanceOf(treasury), 0, "treasury should have stAztec");
        assertGt(stAztec.balanceOf(providerRewards), 0, "provider should have stAztec");

        // Total fee shares should match event
        assertEq(
            stAztec.balanceOf(treasury) + stAztec.balanceOf(providerRewards),
            eventTreasuryShares + eventProviderShares,
            "total fee shares should match"
        );
    }

    /*//////////////////////////////////////////////////////////////
       TEST 1C: TARGET BUFFER CHANGE AFFECTS NEXT REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_GovernanceSetTargetBufferBetweenCycles_AffectsNextRebalance() external {
        // --- Setup: deposit 200e18, keep all buffered, complete first rebalance ---
        _performDeposit(alice, 200 * DECIMALS);

        vm.prank(address(gov));
        core.setTargetBufferedAssets(200 * DECIMALS);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _fullRebalance();

        // After first rebalance: everything is buffered, nothing staked
        assertEq(vault.bufferedAssets(), 200 * DECIMALS, "initial buffer should be 200e18");

        // --- Change targetBufferedAssets from 200e18 to 10e18 via governance ---
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.setTargetBufferedAssets, (10 * DECIMALS)));
        assertEq(core.targetBufferedAssets(), 10 * DECIMALS, "target buffer should be 10e18");

        // --- Configure staking mock: the mock will accept 190e18 stake ---
        stakingManager.setStakeReturnAmount(190 * DECIMALS);
        // Set totalStaked so accounting update reads the correct staked principal
        stakingManager.setTotalStaked(190 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        // --- Rebalance: should stake 190e18 (200 - 10) ---
        _warpPastCooldown();
        (,, uint256 stakedAmount, uint256 resultingBuffer) = _fullRebalance();

        // Verify staking occurred per the new buffer target
        assertEq(stakedAmount, 190 * DECIMALS, "should stake 190e18");
        assertEq(resultingBuffer, 10 * DECIMALS, "buffer should be 10e18 after rebalance");
        assertEq(vault.bufferedAssets(), 10 * DECIMALS, "vault buffer should match target");

        // Rebalance should complete to Done
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 1D: TREASURY FEE SPLIT CHANGE AFFECTS DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    function test_GovernanceTreasuryFeeSplitChange_AffectsDistribution() external {
        // --- Setup: deposit 100e18, complete baseline rebalance ---
        _performDeposit(alice, 100 * DECIMALS);

        vm.prank(address(gov));
        core.setTargetBufferedAssets(1_000 * DECIMALS);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _fullRebalance();

        // --- Change protocolFeeBP to 1000 (10%) for clearer fee calculations ---
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.setProtocolFeeBP, (1_000)));

        // --- Cycle 1: 50/50 split (treasuryFeeSplitBP = 5000 from setUp) ---
        stakingManager.setHarvestedRewards(10 * DECIMALS);
        stakingManager.setClaimableRewards(1);
        _warpPastCooldown();
        _fullRebalance();

        uint256 treasuryBal1 = stAztec.balanceOf(treasury);
        uint256 providerBal1 = stAztec.balanceOf(providerRewards);

        assertGt(treasuryBal1, 0, "cycle1: treasury should have shares");
        assertGt(providerBal1, 0, "cycle1: provider should have shares");

        // With 50/50 split, treasury and provider should be equal
        // Treasury gets floor(total * 5000 / 10000), provider gets remainder -- may differ by 1 wei
        assertApproxEqAbs(treasuryBal1, providerBal1, 1, "cycle1: 50/50 split should yield equal shares");

        // --- Change treasuryFeeSplitBP from 5000 to 9000 (90/10) via governance ---
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.setTreasuryFeeSplitBP, (9_000)));
        assertEq(core.treasuryFeeSplitBP(), 9_000, "treasury split should be 9000");

        // --- Cycle 2: 90/10 split with another 10e18 rewards ---
        stakingManager.setHarvestedRewards(10 * DECIMALS);
        stakingManager.setClaimableRewards(1);
        _warpPastCooldown();
        _fullRebalance();

        uint256 treasuryBal2 = stAztec.balanceOf(treasury);
        uint256 providerBal2 = stAztec.balanceOf(providerRewards);

        // Incremental shares from cycle 2
        uint256 treasuryDelta = treasuryBal2 - treasuryBal1;
        uint256 providerDelta = providerBal2 - providerBal1;

        assertGt(treasuryDelta, 0, "cycle2: treasury delta should be > 0");
        assertGt(providerDelta, 0, "cycle2: provider delta should be > 0");

        // With 90/10 split: treasuryDelta should be ~9x providerDelta (allow 1 wei rounding)
        assertApproxEqAbs(treasuryDelta, providerDelta * 9, 1, "cycle2: treasury should get ~9x provider shares");

        // Total fee shares per cycle should match expected protocol fee (10% of rewards in shares)
        uint256 totalFeeSharesCycle2 = treasuryDelta + providerDelta;
        assertGt(totalFeeSharesCycle2, 0, "cycle2: total fee shares should be > 0");
    }
}
