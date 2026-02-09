// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

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
    OllaCore internal vault;
    StAztec internal stAztec;
    WithdrawalQueue internal withdrawalQueue;

    // Staking contracts
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;

    // Mocks
    MockAztec internal aztec;
    MockAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;

    // Addresses
    address internal core;
    address internal governance;
    address internal providerAdmin;
    address internal defaultAdmin;
    address internal operator;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);

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
        OllaCore vaultImpl = new OllaCore();
        StakingManager stakingImpl = new StakingManager();
        StakingProviderRegistry registryImpl = new StakingProviderRegistry();
        WithdrawalQueue queueImpl = new WithdrawalQueue();

        // Deploy all proxies
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), "");
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImpl), "");

        // Set contract references
        vault = OllaCore(address(vaultProxy));
        stakingManager = StakingManager(address(stakingProxy));
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        // Deploy supporting contracts with vault address
        stAztec = new StAztec(governance, address(vault));
        rewardsVault = new MockRewardsVault(IERC20(address(aztec)), address(vault));
        safetyModule = new MockSafetyModule(address(vault));

        // Initialize stakingProviderRegistry (needs stakingManager address)
        stakingProviderRegistry.initialize(
            address(stakingManager),
            providerAdmin,
            providerAdmin, // rewardsRecipient
            defaultAdmin
        );

        // Initialize stakingManager with vault as core
        stakingManager.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsVault),
            address(vault), // vault is the core!
            address(stakingProviderRegistry),
            defaultAdmin
        );

        // Initialize vault
        vault.initialize(
            IERC20(address(aztec)),
            stAztec,
            stakingManager,
            0, // deposit cap
            0, // withdrawal minimum
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        // Initialize withdrawalQueue
        withdrawalQueue.initialize(address(vault), governance);

        // Setup roles
        vm.startPrank(governance);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        stAztec.grantRole(stAztec.MINTER_ROLE(), address(vault));
        stAztec.grantRole(stAztec.BURNER_ROLE(), address(vault));
        vm.stopPrank();
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

        vm.startPrank(operator);
        vault.rebalance();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test demonstrating the external exit bug.
    /// @dev This test shows how funds get stuck when attesters exit externally:
    ///      1. Stake 2 attesters (both in _activatedAttesters)
    ///      2. Alice deposits 200 ether
    ///      3. Rebalance stakes Alice's deposit (now 2 attesters activated)
    ///      4. Alice requests withdrawal of 100 ether
    ///      5. Rebalance #1 initiates unstake for 1 attester -> moves to _pendingUnstakeRequests
    ///      6. The remaining attester in _activatedAttesters exits externally!
    ///      7. Rebalance #2: _finalizePendingUnstakes processes pending attester (claims 100 ether)
    ///         - BUT hasExitableUnstakes() returns true because activated attester has exit!
    ///         - Rebalance returns early, never claims the 100 ether from external exit
    ///      8. BUG: Only 100 ether claimed, 100 ether stuck forever in _activatedAttesters
    function test_ExternalExit_Bug_FundsStuckInActivatedAttesters() external {
        //
        // rebalance() steps:
        // 1. Harvest - harvest rewards
        // 2. PullUnstaked - call _pullUnstakedFunds() which calls getUnstakedFunds()
        //    - getUnstakedFunds() calls _claimUnstakedFunds() -> _finalizePendingUnstakes()
        //    - _finalizePendingUnstakes() only processes _pendingUnstakeRequests
        //    - If hasExitableUnstakes() returns true (exits exist), rebalance returns early
        // 3. FinalizeWithdrawals - only runs if hasExitableUnstakes() returned false
        //
        // So the bug is:
        // - Attesters exit externally while in _activatedAttesters
        // - hasExitableUnstakes() returns true
        // - rebalance returns early at PullUnstaked step
        // - Never reaches FinalizeWithdrawals
        // - Withdrawals stuck forever

        // But how do attesters get into _activatedAttesters and then exit externally?
        // Answer: They get staked, then exit via rollup directly (e.g., validator chooses to exit).
        // The protocol doesn't know until cleanActivatedAttesters() is called or unstake() is attempted.

        // Scenario:
        // 1. Stake 2 attesters (both in _activatedAttesters)
        // 2. Alice deposits 100 ether
        // 3. Alice requests withdrawal of 50 ether
        // 4. Rebalance #1:
        //    - PullUnstaked: _finalizePendingUnstakes finds nothing (no pending unstakes)
        //    - hasExitableUnstakes() returns false (no exits yet)
        //    - Proceed to InitiateUnstake
        //    - InitiateUnstake: unstake(50 ether) - unstakes 1 attester, moves to _pendingUnstakeRequests
        //    - 1 attester remains in _activatedAttesters
        // 5. The remaining attester exits externally (e.g., via rollup)
        // 6. Rebalance #2:
        //    - PullUnstaked: _finalizePendingUnstakes processes the 1 pending unstake (if exitable)
        //    - But wait, the attester in _activatedAttesters also has an exit!
        //    - hasExitableUnstakes() checks BOTH lists and returns true
        //    - rebalance returns early!
        // 7. Funds from the externally-exited attester are never claimed
        // 8. But Alice's withdrawal might still be finalized if we got enough from the first attester

        // Hmm, let me adjust the scenario to make it clearly a bug:
        // 1. Stake 1 attester with 100 ether
        // 2. Alice deposits 100 ether (buffer = 100)
        // 3. Rebalance stakes Alice's deposit to a 2nd attester
        //    - Now 2 attesters in _activatedAttesters (200 ether total staked)
        // 4. Alice requests withdrawal of 100 ether
        // 5. Rebalance #1:
        //    - PullUnstaked: nothing to claim
        //    - InitiateUnstake: unstake(100 ether) - unstakes 1 attester
        //    - 1 attester moves to _pendingUnstakeRequests
        //    - 1 attester remains in _activatedAttesters
        // 6. The remaining attester exits externally (slashed or voluntary)
        //    - Now: 1 in _pendingUnstakeRequests (exitable), 1 in _activatedAttesters (exitable)
        // 7. Rebalance #2:
        //    - PullUnstaked: _finalizePendingUnstakes processes 1 attester from pending
        //    - BUT hasExitableUnstakes() returns true because the 1 in _activatedAttesters is exitable!
        //    - rebalance returns early at line 405-408
        //    - bufferedAssets += claimed amount from 1 attester (100 ether)
        //    - But we have 200 ether worth of exits available!
        //    - The 2nd attester's 100 ether is stuck
        // 8. bufferedAssets = 100, but totalPending = 100, so _finalizeWithdrawals can run
        //    - Alice gets her 100 ether
        //    - But the vault loses 100 ether that should be in the buffer!

        // Actually wait, let me re-read hasExitableUnstakes()...
        // It checks both lists for withdrawableAmount != 0
        // So if ANY attester in either list is exitable, it returns true
        // This causes early return

        // The problem is: getUnstakedFunds() should claim ALL exitable funds,
        // not just from _pendingUnstakeRequests. But it only calls _finalizePendingUnstakes().

        // OK let me write the test with this understanding:

        // Setup: Need to stake 2 attesters with enough funds
        // 1. Add 2 attester keys
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        // 2. Alice deposits 200 ether
        uint256 depositAmount = 200 ether;
        aztec.mint(alice, depositAmount);
        vm.startPrank(alice);
        aztec.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // 3. Rebalance to stake all funds (will stake to both attesters)
        vm.prank(operator);
        vault.rebalance();

        // Verify: 2 activated attesters, 200 ether staked
        assertEq(stakingManager.getActivatedAttesterCount(), 2, "Should have 2 activated attesters");
        assertEq(stakingManager.totalStaked(), 200 ether, "Should have 200 ether staked");

        // 4. Alice requests withdrawal of 100 ether (1 attester worth)
        uint256 withdrawShares = stAztec.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(withdrawShares, alice);

        // 5. Rebalance #1 - initiates unstake for 1 attester
        // This will move 1 attester to _pendingUnstakeRequests
        vm.prank(operator);
        vault.rebalance();

        // Verify: 1 in _activatedAttesters, 1 in _pendingUnstakeRequests
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "Should have 1 activated attester");
        assertEq(stakingManager.getPendingUnstakeCount(), 1, "Should have 1 pending unstake");

        // 6. The remaining attester in _activatedAttesters exits externally!
        // Get the attester address that's still activated
        // From _createMockKeys, attesters are at addresses 1, 2, ...
        // We staked to 2 attesters, one was unstaked (moved to pending), one remains
        // The pending one would be address(1) (first one processed)
        // The activated one would be address(2)
        address activatedAttester = address(uint160(2));

        // Simulate external exit on the rollup
        rollup.setExternalExit(activatedAttester, ACTIVATION_THRESHOLD, block.timestamp);

        // After this rebalance the vault will have surplus buffer (claimed exits minus withdrawal).
        // Keep that surplus buffered so the test doesn't depend on having extra staking keys.
        vm.prank(governance);
        vault.setTargetBufferedAssets(100 ether);

        // Verify: exit exists in rollup for the activated attester
        assertTrue(rollup.getExit(activatedAttester).exists, "Exit should exist in rollup");

        // Verify: hasExitableUnstakes() returns true (this is the key check)
        // It checks both _activatedAttesters and _pendingUnstakeRequests
        assertTrue(stakingManager.hasExitableUnstakes(), "hasExitableUnstakes should return true");

        // 7. Rebalance #2 - This is where the bug manifests
        // _pullUnstakedFunds() calls getUnstakedFunds()
        // getUnstakedFunds() calls _finalizePendingUnstakes() which only processes _pendingUnstakeRequests
        // It does NOT process the attester in _activatedAttesters that has an external exit!
        // Then hasExitableUnstakes() returns true (because activated attester has exit)
        // So rebalance returns early at line 405-408
        // The 100 ether from the externally-exited attester is NEVER claimed!

        uint256 vaultBalanceBefore = aztec.balanceOf(address(vault));

        vm.prank(operator);
        vault.rebalance();

        // Assert on the vault's asset balance delta rather than bufferedAssets.
        // With the fix, rebalance proceeds to FinalizeWithdrawals in the same call,
        // which can decrease bufferedAssets without affecting the vault's token balance.
        uint256 expectedClaimed = 200 ether;
        uint256 actualClaimed = aztec.balanceOf(address(vault)) - vaultBalanceBefore;
        assertEq(actualClaimed, expectedClaimed, "Should have claimed both exits (200 ether)");

        // Also verify the withdrawal is finalized
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        assertTrue(request.finalized, "Withdrawal should be finalized");
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
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // 2. Rebalance to stake all funds
        vm.prank(operator);
        vault.rebalance();

        // Verify: 2 attesters staked
        assertEq(stakingManager.totalStaked(), 200 ether, "Should have 200 ether staked");

        // 3. Alice requests withdrawal of 150 ether
        // This is the key: 150 ether requires unstaking 1.5 attesters
        // But attesters are discrete 100-ether units!
        uint256 aliceShares = stAztec.balanceOf(alice);
        uint256 withdrawShares = (150 ether * aliceShares) / vault.totalAssets();
        vm.prank(alice);
        vault.requestRedeem(withdrawShares, alice);

        uint256 pendingBefore = withdrawalQueue.totalPendingAssets();
        assertApproxEqAbs(pendingBefore, 150 ether, 1 ether, "Should have ~150 ether pending");

        // 4. Trigger rebalance - this should hit the underflow bug
        // The rebalance will try to initiate unstake for 150 ether
        // But StakingManager will unstake 2 full attesters (200 ether)
        // Then progress.unstakeRemaining -= 200 will underflow!

        // This call should revert with arithmetic underflow
        vm.prank(operator);
        vault.rebalance();

        // If we reach here without revert, the bug is fixed
        // If it reverts with "panic: arithmetic underflow or overflow (0x11)", the bug exists

        // Verify the withdrawal was processed correctly
        // (This code won't be reached if the bug exists)
        uint256 pendingAfter = withdrawalQueue.totalPendingAssets();

        // Protocol should handle the case where initiated > requested gracefully
        // Either by allowing it (initiating more unstake than strictly needed)
        // Or by properly tracking the excess
        assertLe(pendingAfter, pendingBefore, "Some or all of the withdrawal should be processed");
    }
}
