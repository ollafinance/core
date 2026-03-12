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

/// @title FeeMintingDistributionE2ETest
/// @notice E2E: validates protocol fee minting, share dilution, and treasury/provider split.
///         Wires real OllaGovernance (timelock), OllaCore, OllaVault, WithdrawalQueue, SafetyModule
///         with MockAccountingStakingManager and MockRewardsAccumulator.
contract FeeMintingDistributionE2ETest is Test {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OllaProtocolFeesPaid(uint256 protocolFeeAssets, uint256 treasuryShares, uint256 providerShares);
    event FeesMinted(uint256 treasuryShares, uint256 providerShares);

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
            7 days // maxAccountingDelay
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

    /// @dev Establishes a baseline rebalance with high target buffer and zero rewards.
    function _baselineRebalance() internal {
        vm.prank(address(gov));
        core.setTargetBufferedAssets(1_000_000 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        _fullRebalance();
    }

    /// @dev Simulates rewards and triggers a rebalance cycle.
    function _rebalanceWithRewards(uint256 rewardAmount) internal {
        stakingManager.setHarvestedRewards(rewardAmount);
        stakingManager.setClaimableRewards(1); // bypass idle buffer optimisation
        _warpPastCooldown();
        _fullRebalance();
    }

    /// @dev Searches recorded logs for OllaProtocolFeesPaid on core.
    function _findFeeEvent(Vm.Log[] memory entries)
        internal
        view
        returns (bool found, uint256 feeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        bytes32 topic = OllaProtocolFeesPaid.selector;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(core) && entries[i].topics[0] == topic) {
                (feeAssets, treasuryShares, providerShares) = abi.decode(entries[i].data, (uint256, uint256, uint256));
                return (true, feeAssets, treasuryShares, providerShares);
            }
        }
    }

    /// @dev Searches recorded logs for FeesMinted on vault.
    function _findFeesMintedEvent(Vm.Log[] memory entries)
        internal
        view
        returns (bool found, uint256 treasuryShares, uint256 providerShares)
    {
        bytes32 topic = FeesMinted.selector;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(vault) && entries[i].topics[0] == topic) {
                (treasuryShares, providerShares) = abi.decode(entries[i].data, (uint256, uint256));
                return (true, treasuryShares, providerShares);
            }
        }
    }

    /// @dev Computes the asset value of a share amount using the core's pricing.
    function _shareValue(uint256 shares) internal view returns (uint256) {
        uint256 total = core.totalAssets();
        uint256 supply = stAztec.totalSupply();
        return shares * (total + 1) / (supply + 1);
    }

    /*//////////////////////////////////////////////////////////////
        TEST 2A: FEE MINTING — CORRECT SHARES AND DILUTION
    //////////////////////////////////////////////////////////////*/

    function test_FeeMinting_CorrectSharesAndDilution() external {
        // --- Setup: protocolFeeBP = 1000 (10%), treasuryFeeSplitBP = 5000 (50/50) ---
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.setProtocolFeeBP, (1_000)));
        assertEq(core.protocolFeeBP(), 1_000, "protocolFeeBP should be 1000");

        _performDeposit(alice, 100 * DECIMALS);
        _baselineRebalance();

        assertEq(core.totalAssets(), 100 * DECIMALS, "pre: totalAssets should be 100e18");
        assertEq(stAztec.totalSupply(), 100 * DECIMALS, "pre: totalSupply should be 100e18");
        assertEq(stAztec.balanceOf(treasury), 0, "pre: treasury should have 0");
        assertEq(stAztec.balanceOf(providerRewards), 0, "pre: provider should have 0");

        // --- Action: simulate 20e18 rewards and rebalance ---
        vm.recordLogs();
        _rebalanceWithRewards(20 * DECIMALS);

        // --- Verify OllaProtocolFeesPaid event ---
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (bool feeFound, uint256 eventFeeAssets, uint256 eventTreasuryShares, uint256 eventProviderShares) =
            _findFeeEvent(entries);
        assertTrue(feeFound, "OllaProtocolFeesPaid should be emitted");
        assertEq(eventFeeAssets, 2 * DECIMALS, "feeAssets should be 2e18 (10% of 20e18)");

        // --- Verify FeesMinted event on vault ---
        (bool mintFound, uint256 mintTreasury, uint256 mintProvider) = _findFeesMintedEvent(entries);
        assertTrue(mintFound, "FeesMinted should be emitted on vault");
        assertEq(mintTreasury, eventTreasuryShares, "FeesMinted treasuryShares matches core event");
        assertEq(mintProvider, eventProviderShares, "FeesMinted providerShares matches core event");

        // --- Verify 50/50 split ---
        uint256 treasuryBal = stAztec.balanceOf(treasury);
        uint256 providerBal = stAztec.balanceOf(providerRewards);
        assertGt(treasuryBal, 0, "treasury should hold stAztec");
        assertGt(providerBal, 0, "provider should hold stAztec");
        // Treasury gets floor(total * 5000 / 10000), provider gets remainder -- may differ by 1 wei
        assertApproxEqAbs(treasuryBal, providerBal, 1, "50/50 split: treasury ~= provider shares");
        assertEq(treasuryBal, eventTreasuryShares, "treasury balance matches event");
        assertEq(providerBal, eventProviderShares, "provider balance matches event");

        // --- Verify dilution ---
        uint256 totalSupply = stAztec.totalSupply();
        assertGt(totalSupply, 100 * DECIMALS, "totalSupply should increase from fee minting");
        assertEq(totalSupply, 100 * DECIMALS + treasuryBal + providerBal, "totalSupply = alice + fees");

        // --- Verify totalAssets ---
        assertApproxEqAbs(core.totalAssets(), 120 * DECIMALS, 2, "totalAssets ~= 120e18");

        // --- Verify conservation: all share values ~= totalAssets ---
        uint256 aliceValue = _shareValue(stAztec.balanceOf(alice));
        uint256 treasuryValue = _shareValue(treasuryBal);
        uint256 providerValue = _shareValue(providerBal);
        assertApproxEqAbs(
            aliceValue + treasuryValue + providerValue, core.totalAssets(), 3, "conservation: sum ~= totalAssets"
        );

        // Alice's share value should be diluted (less than 120e18) but retain most rewards
        assertLt(aliceValue, 120 * DECIMALS, "alice diluted: value < 120e18");
        assertGt(aliceValue, 117 * DECIMALS, "alice retains most rewards: value > 117e18");
    }

    /*//////////////////////////////////////////////////////////////
          TEST 2B: ZERO REWARDS — NO FEE MINTING
    //////////////////////////////////////////////////////////////*/

    function test_FeeMinting_ZeroRewards_NoMint() external {
        _performDeposit(alice, 100 * DECIMALS);
        _baselineRebalance();

        uint256 supplyBefore = stAztec.totalSupply();

        // --- Action: simulate 0 rewards, rebalance ---
        vm.recordLogs();
        _rebalanceWithRewards(0);

        // --- Verify no fees minted ---
        assertEq(stAztec.balanceOf(treasury), 0, "treasury should have 0 shares");
        assertEq(stAztec.balanceOf(providerRewards), 0, "provider should have 0 shares");
        assertEq(stAztec.totalSupply(), supplyBefore, "totalSupply should not change");

        // If OllaProtocolFeesPaid emitted, it must have 0 values
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (bool found, uint256 feeAssets, uint256 tShares, uint256 pShares) = _findFeeEvent(entries);
        if (found) {
            assertEq(feeAssets, 0, "feeAssets should be 0");
            assertEq(tShares, 0, "treasuryShares should be 0");
            assertEq(pShares, 0, "providerShares should be 0");
        }
    }

    /*//////////////////////////////////////////////////////////////
          TEST 2C: ZERO FEE BP — NO FEE MINTING
    //////////////////////////////////////////////////////////////*/

    function test_FeeMinting_ZeroFeeBP_NoMint() external {
        // --- Change protocolFeeBP to 0 via governance ---
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.setProtocolFeeBP, (0)));
        assertEq(core.protocolFeeBP(), 0, "protocolFeeBP should be 0");

        _performDeposit(alice, 100 * DECIMALS);
        _baselineRebalance();

        uint256 supplyBefore = stAztec.totalSupply();

        // --- Action: simulate 10e18 rewards ---
        _rebalanceWithRewards(10 * DECIMALS);

        // --- Verify no fees minted ---
        assertEq(stAztec.balanceOf(treasury), 0, "treasury should have 0 shares");
        assertEq(stAztec.balanceOf(providerRewards), 0, "provider should have 0 shares");
        assertEq(stAztec.totalSupply(), supplyBefore, "totalSupply unchanged");

        // --- All rewards go to alice ---
        assertApproxEqAbs(core.totalAssets(), 110 * DECIMALS, 2, "totalAssets ~= 110e18");
        uint256 aliceValue = _shareValue(stAztec.balanceOf(alice));
        assertApproxEqAbs(aliceValue, 110 * DECIMALS, 2, "alice gets full rewards ~= 110e18");
    }

    /*//////////////////////////////////////////////////////////////
          TEST 2D: MULTI-CYCLE FEE ACCUMULATION
    //////////////////////////////////////////////////////////////*/

    function test_FeeMinting_MultiCycle_Accumulation() external {
        // --- Setup: protocolFeeBP = 500 (5%), treasuryFeeSplitBP = 7000 (70/30) ---
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.setTreasuryFeeSplitBP, (7_000)));
        assertEq(core.treasuryFeeSplitBP(), 7_000, "treasury split should be 7000");

        _performDeposit(alice, 1_000 * DECIMALS);
        _baselineRebalance();

        assertEq(core.totalAssets(), 1_000 * DECIMALS, "pre: totalAssets = 1000e18");

        // --- Cycle 1: 50e18 rewards ---
        _rebalanceWithRewards(50 * DECIMALS);

        uint256 treasuryBal1 = stAztec.balanceOf(treasury);
        uint256 providerBal1 = stAztec.balanceOf(providerRewards);
        uint256 totalSupply1 = stAztec.totalSupply();
        uint256 totalAssets1 = core.totalAssets();

        assertGt(treasuryBal1, 0, "cycle1: treasury should have shares");
        assertGt(providerBal1, 0, "cycle1: provider should have shares");
        // 70/30 split: treasuryBal * 3 ~= providerBal * 7
        assertApproxEqAbs(treasuryBal1 * 3, providerBal1 * 7, 10, "cycle1: 70/30 split");
        assertApproxEqAbs(totalAssets1, 1_050 * DECIMALS, 2, "cycle1: totalAssets ~= 1050e18");

        // --- Cycle 2: 30e18 rewards ---
        _rebalanceWithRewards(30 * DECIMALS);

        uint256 treasuryBal2 = stAztec.balanceOf(treasury);
        uint256 providerBal2 = stAztec.balanceOf(providerRewards);
        uint256 totalSupply2 = stAztec.totalSupply();
        uint256 totalAssets2 = core.totalAssets();

        uint256 treasuryDelta2 = treasuryBal2 - treasuryBal1;
        uint256 providerDelta2 = providerBal2 - providerBal1;

        assertGt(treasuryDelta2, 0, "cycle2: treasury delta > 0");
        assertGt(providerDelta2, 0, "cycle2: provider delta > 0");
        assertApproxEqAbs(treasuryDelta2 * 3, providerDelta2 * 7, 10, "cycle2: 70/30 split maintained");
        assertApproxEqAbs(totalAssets2, 1_080 * DECIMALS, 3, "cycle2: totalAssets ~= 1080e18");
        assertGt(totalSupply2, totalSupply1, "cycle2: totalSupply increased");

        // --- Cycle 3: 0 rewards (no new fees) ---
        _rebalanceWithRewards(0);

        uint256 treasuryBal3 = stAztec.balanceOf(treasury);
        uint256 providerBal3 = stAztec.balanceOf(providerRewards);
        uint256 totalSupply3 = stAztec.totalSupply();
        uint256 totalAssets3 = core.totalAssets();

        assertEq(treasuryBal3, treasuryBal2, "cycle3: treasury unchanged (0 rewards)");
        assertEq(providerBal3, providerBal2, "cycle3: provider unchanged (0 rewards)");
        assertEq(totalSupply3, totalSupply2, "cycle3: totalSupply unchanged");
        assertApproxEqAbs(totalAssets3, totalAssets2, 2, "cycle3: totalAssets unchanged");

        // --- Conservation across all cycles ---
        uint256 aliceValue = _shareValue(stAztec.balanceOf(alice));
        uint256 treasuryValue = _shareValue(treasuryBal3);
        uint256 providerValue = _shareValue(providerBal3);
        assertApproxEqAbs(
            aliceValue + treasuryValue + providerValue, totalAssets3, 5, "conservation: all share values ~= totalAssets"
        );

        // Final totalAssets should be 1000 + 50 + 30 = 1080 (within rounding)
        assertApproxEqAbs(totalAssets3, 1_080 * DECIMALS, 3, "final totalAssets ~= 1080e18");
    }

    /*//////////////////////////////////////////////////////////////
      TEST 2E: SLASHING NEGATES REWARDS — ZERO FEES
    //////////////////////////////////////////////////////////////*/

    function test_FeeMinting_WithSlashing_ReducedOrZeroFees() external {
        // --- Setup: protocolFeeBP = 1000 (10%), targetBuffer = 0, stake all ---
        _scheduleAndExecute(address(gov), abi.encodeCall(IOllaGovernance.setProtocolFeeBP, (1_000)));
        _scheduleAndExecute(
            address(gov), abi.encodeCall(IOllaGovernance.setTargetBufferedAssets, (0)), bytes32(uint256(1))
        );

        _performDeposit(alice, 100 * DECIMALS);

        // Configure mock: stake 100e18 on first rebalance
        stakingManager.setStakeReturnAmount(100 * DECIMALS);
        stakingManager.setTotalStaked(100 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        _warpPastCooldown();
        _fullRebalance();

        assertEq(vault.bufferedAssets(), 0, "pre: all assets staked, buffer = 0");
        assertEq(core.totalAssets(), 100 * DECIMALS, "pre: totalAssets = 100e18");

        // --- Action: slashing 15e18, small reward 5e18 ---
        // totalStaked = 105 (original 100 + 5 newly staked from harvested rewards) pre-slash.
        // slashingDelta = 15 → totalStaked reduced to 90 (net-of-slashing).
        stakingManager.setTotalStaked(105 * DECIMALS);
        stakingManager.setSlashingDelta(15 * DECIMALS);
        stakingManager.setHarvestedRewards(5 * DECIMALS);
        stakingManager.clearStakeReturnAmount();

        _warpPastCooldown();
        vm.recordLogs();
        _fullRebalance();

        // --- Verify: slashing > rewards → grossRewards = 0 → no fees ---
        assertEq(stAztec.balanceOf(treasury), 0, "treasury should have 0 (slashing negated rewards)");
        assertEq(stAztec.balanceOf(providerRewards), 0, "provider should have 0");
        assertEq(stAztec.totalSupply(), 100 * DECIMALS, "totalSupply unchanged (no fee minting)");

        // totalAssets should be ~90e18 (105 staked - 15 slashing)
        assertApproxEqAbs(core.totalAssets(), 90 * DECIMALS, 2, "totalAssets ~= 90e18");

        // Exchange rate dropped below 1:1
        IOllaCore.LatestReport memory report = core.latestReport();
        assertLt(report.exchangeRate, 1e18, "exchange rate should drop below 1e18");

        // If fee event was emitted, it must have zero fee assets
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (bool found, uint256 feeAssets,,) = _findFeeEvent(entries);
        if (found) {
            assertEq(feeAssets, 0, "feeAssets should be 0 when slashing negates rewards");
        }
    }
}
