// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";
import { Vm } from "@forge-std/Vm.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title ExternalExitIntegrationTest
/// @notice Integration test demonstrating the external exit bug.
/// @dev This test uses real OllaCore and real StakingManager with mocked rollup.
///      The bug: When attesters exit externally (outside protocol flow), they remain
///      in _activatedAttesters but have exits ready. hasExitableUnstakes() returns true,
///      causing rebalance to return early. But _finalizePendingUnstakes() only processes
///      _pendingUnstakeRequests, so the funds are never claimed. Withdrawals remain pending forever.
/// @author Olla Core contributors
contract ExternalExitIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant ACTIVATION_THRESHOLD = 100 ether;
    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    // Core contracts
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    WithdrawalQueue internal withdrawalQueue;

    // Staking contracts
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;

    // Mocks
    MockAztec internal aztec;
    MockAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    // Addresses
    address internal governance;
    address internal providerAdmin;
    address internal defaultAdmin;
    address internal operator;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);
    event UnstakedFundsClaimed(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        governance = makeAddr("governance");
        providerAdmin = makeAddr("providerAdmin");
        defaultAdmin = makeAddr("defaultAdmin");
        operator = makeAddr("operator");
        alice = makeAddr("alice");

        // Deploy token
        aztec = new MockAztec(address(this));

        // Deploy rollup mocks
        rollup = new MockAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        rollupRegistry = new MockAztecRollupRegistry(address(rollup));

        // Deploy all implementations first
        OllaCore coreImpl = new OllaCore();
        StakingManager stakingImpl = new StakingManager();
        StakingProviderRegistry registryImpl = new StakingProviderRegistry();
        WithdrawalQueue queueImpl = new WithdrawalQueue();
        OllaVault vaultImpl = new OllaVault();

        // Deploy all proxies
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), "");
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), "");
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImpl), "");
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");

        // Set contract references
        core = OllaCore(address(coreProxy));
        vault = OllaVault(address(vaultProxy));
        stakingManager = StakingManager(address(stakingProxy));
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        // Deploy supporting contracts
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(IERC20(address(aztec)), address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        // Initialize stakingProviderRegistry (needs stakingManager address)
        stakingProviderRegistry.initialize(
            address(stakingManager),
            providerAdmin,
            providerAdmin, // rewardsRecipient
            defaultAdmin
        );

        // Initialize stakingManager with core
        stakingManager.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsAccumulator),
            address(core),
            address(stakingProviderRegistry),
            defaultAdmin
        );

        // Initialize withdrawalQueue (must happen before vault.initialize)
        withdrawalQueue.initialize(address(vault), governance, 180_000);

        // Initialize core
        core.initialize(
            IERC20(address(aztec)),
            stAztec,
            stakingManager,
            0, // protocolFeeBP
            5_000, // treasuryFeeSplitBP
            governance,
            rewardsAccumulator,
            address(safetyModule)
        );

        // Initialize vault
        vault.initialize(
            IERC20(address(aztec)), stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance
        );

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        // Setup roles
        vm.startPrank(governance);
        core.grantRole(core.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _createMockKeys(uint256 count) internal pure returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = IStakingManager.KeyStore({
                attester: address(uint160(i + 1)),
                publicKeyG1: G1Point({ x: i, y: i + 1 }),
                publicKeyG2: G2Point({ x0: i, x1: i + 1, y0: i + 2, y1: i + 3 }),
                proofOfPossession: G1Point({ x: i + 10, y: i + 11 })
            });
        }
        return keys;
    }

    function _setupStakedAttesters(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * count;
        aztec.mint(address(vault), stakeAmount);

        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        core.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice External exits can be reconciled during rebalance.
    /// @dev computeAttesterState() syncs Active->Exiting before rebalance claims exits.
    function test_ExternalExit_ReconciledDuringRebalance() external {
        // 1. Add 2 attester keys
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        // 2. Alice deposits 200 ether
        uint256 depositAmount = 200 ether;
        aztec.mint(alice, depositAmount);
        vm.startPrank(alice);
        aztec.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice, 0);
        vm.stopPrank();

        // 3. Rebalance to stake all funds (will stake to both attesters)
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        core.rebalance();

        // Refresh cached state after staking and update accounting to get correct exchange rate
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        core.updateAccounting();

        // Verify: 2 activated attesters, 200 ether staked
        assertEq(stakingManager.getActivatedAttesterCount(), 2, "Should have 2 activated attesters");
        assertEq(stakingManager.totalStaked(), 200 ether, "Should have 200 ether staked");

        // 4. Alice requests withdrawal of 100 ether (1 attester worth)
        uint256 withdrawShares = stAztec.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(withdrawShares, alice, alice);

        // 5. Rebalance #1 - initiates unstake for 1 attester
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        core.rebalance();

        // Verify: 1 active, 1 exiting
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "Should have 1 activated attester");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "Should have 1 pending unstake");

        // 6. The remaining activated attester exits externally
        address activatedAttester = address(uint160(2));
        rollup.setExternalExit(activatedAttester, ACTIVATION_THRESHOLD, block.timestamp);

        // Refresh cached state to reflect external exit
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        // Verify: exit exists in rollup for the activated attester
        assertTrue(rollup.getExit(activatedAttester).exists, "Exit should exist in rollup");
        assertTrue(stakingManager.hasExitableUnstakes(), "hasExitableUnstakes should be true for active exitable exits");

        uint256 bufferBefore = vault.bufferedAssets();

        IStakingManager.KeyStore[] memory additionalKeys = _createMockKeys(1);
        additionalKeys[0].attester = address(uint160(3));
        additionalKeys[0].publicKeyG1 = G1Point({ x: 2, y: 3 });
        additionalKeys[0].publicKeyG2 = G2Point({ x0: 2, x1: 3, y0: 4, y1: 5 });
        additionalKeys[0].proofOfPossession = G1Point({ x: 12, y: 13 });
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(additionalKeys);

        uint256 expectedGrossClaimed = 200 ether; // Both exits should be claimed

        vm.recordLogs();

        // Single rebalance call: claims exits AND completes the full cycle
        // because getUnstakedFunds() returns hasRemainingExits=false (via _exitingCount)
        // after all exiting attesters have been finalized.
        {
            IOllaCore.LatestReport memory rpt = core.latestReport();
            vm.warp(rpt.timestamp + 1 hours + 1);
        }
        stakingManager.finalizeExits();
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        (, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) = core.rebalance();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundEvent = false;
        bytes32 expectedSelector = keccak256("UnstakedFundsClaimed(uint256)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(core) && entries[i].topics[0] == expectedSelector) {
                uint256 claimed = abi.decode(entries[i].data, (uint256));
                assertEq(claimed, expectedGrossClaimed);
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "UnstakedFundsClaimed event not found");

        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        uint256 expectedFinalized = request.assetsExpected;
        uint256 expectedStaked = ACTIVATION_THRESHOLD;
        uint256 expectedResultingBuffer = bufferBefore + expectedGrossClaimed - expectedFinalized - expectedStaked;

        assertEq(finalizedAmount, expectedFinalized, "Finalized amount should net withdrawal");
        assertEq(stakedAmount, expectedStaked, "Staked amount should net surplus buffer");
        assertEq(resultingBuffer, expectedResultingBuffer, "Resulting buffer should reflect net rebalance");

        // Also verify the withdrawal is finalized
        assertTrue(request.finalized, "Withdrawal should be finalized");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "All unstakes should be finalized");
    }

    function test_Rebalance_ClaimsExternallyFinalizedExit() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 depositAmount = ACTIVATION_THRESHOLD;
        aztec.mint(alice, depositAmount);
        vm.startPrank(alice);
        aztec.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice, 0);
        vm.stopPrank();

        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        core.rebalance();

        // Refresh cached state after staking
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        vm.prank(governance);
        core.setTargetBufferedAssets(depositAmount);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        core.rebalance();

        // Refresh cached state after unstake
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();

        assertEq(stakingManager.getPendingUnstakeCount(), 1, "pending unstake should be created");

        address attester = keys[0].attester;
        vm.prank(makeAddr("external"));
        rollup.finalizeWithdraw(attester);

        uint256 managerBalance = aztec.balanceOf(address(stakingManager));
        assertEq(managerBalance, depositAmount, "manager should hold externally finalized exit");

        uint256 vaultBalanceBefore = aztec.balanceOf(address(vault));

        {
            IOllaCore.LatestReport memory rpt = core.latestReport();
            vm.warp(rpt.timestamp + 1 hours + 1);
        }
        stakingManager.finalizeExits();
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        core.rebalance();

        uint256 vaultBalanceAfter = aztec.balanceOf(address(vault));
        assertEq(
            vaultBalanceAfter,
            vaultBalanceBefore + managerBalance,
            "vault balance should increase by externally finalized amount"
        );
        assertEq(aztec.balanceOf(address(stakingManager)), 0, "manager balance should clear after pull");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending unstake count should clear");
    }

    /// @notice Test demonstrating the unstake underflow bug.
    /// @dev This test reproduces the arithmetic underflow that occurs when
    ///      _initiateUnstake() returns more than requested (due to discrete attesters).
    ///
    ///      Bug Location: OllaCore.sol line 524
    ///      ```solidity
    ///      uint256 initiated = _initiateUnstake(progress.unstakeRemaining);
    ///      progress.unstakeRemaining -= initiated;  // BUG: Underflows if initiated > requested!
    ///      ```
    ///
    ///      The Bug:
    ///      - User requests withdrawal of 150 ether (need to unstake 1.5 attesters)
    ///      - Rebalance calls _initiateUnstake(150 ether)
    ///      - But attesters are discrete 100-ether units!
    ///      - StakingManager unstakes 2 attesters = 200 ether
    ///      - Returns initiated = 200 ether
    ///      - progress.unstakeRemaining = 150 - 200 = UNDERFLOW! (panic: 0x11)
    function test_UnstakeUnderflow_Bug_InitiatedExceedsRequested() external {
        // Setup: Stake 2 attesters (200 ether total)
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        // 1. Alice deposits 200 ether
        uint256 depositAmount = 200 ether;
        aztec.mint(alice, depositAmount);
        vm.startPrank(alice);
        aztec.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice, 0);
        vm.stopPrank();

        // 2. Rebalance to stake all funds
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        core.rebalance();

        // Refresh cached state after staking and update accounting so totalAssets reflects staked principal
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        core.updateAccounting();

        // Verify: 2 attesters staked
        assertEq(stakingManager.totalStaked(), 200 ether, "Should have 200 ether staked");

        // 3. Alice requests withdrawal of 150 ether
        // This is the key: 150 ether requires unstaking 1.5 attesters
        // But attesters are discrete 100-ether units!
        uint256 aliceShares = stAztec.balanceOf(alice);
        uint256 withdrawShares = (150 ether * aliceShares) / core.totalAssets();
        vm.prank(alice);
        vault.requestRedeem(withdrawShares, alice, alice);

        uint256 pendingBefore = withdrawalQueue.totalPendingAssets();
        assertApproxEqAbs(pendingBefore, 150 ether, 1 ether, "Should have ~150 ether pending");

        // 4. Trigger rebalance - this should NOT underflow after clamp fix
        // The rebalance will try to initiate unstake for 150 ether
        // But StakingManager will unstake 2 full attesters (200 ether)
        // progress.unstakeRemaining should clamp to 0 instead of underflowing

        vm.warp(block.timestamp + 1 hours);
        vm.prank(defaultAdmin);
        stakingManager.computeAttesterState();
        vm.prank(operator);
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) =
            core.rebalance();

        assertEq(rewardsDelta, 0, "Rewards delta should be zero in this flow");
        assertEq(finalizedAmount, 0, "Finalize should not run before unstake finalizes");
        assertEq(stakedAmount, 0, "No surplus should be staked during unstake initiation");
        assertEq(resultingBuffer, 0, "Buffer should remain zero after initiate unstake");

        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(progress.unstakeRemaining, 0, "unstake remaining should clamp to zero");

        uint256 pendingAfter = withdrawalQueue.totalPendingAssets();
        assertEq(pendingAfter, pendingBefore, "Pending withdrawals should remain queued");
        assertEq(stakingManager.getPendingUnstakeCount(), 2, "Pending unstakes should include both attesters");
        IStakingManager.KeyStore[] memory keysAfter = _createMockKeys(2);
        assertTrue(stakingManager.isUnstakePending(keysAfter[0].attester), "Attester 0 should be pending");
        assertTrue(stakingManager.isUnstakePending(keysAfter[1].attester), "Attester 1 should be pending");
    }
}
