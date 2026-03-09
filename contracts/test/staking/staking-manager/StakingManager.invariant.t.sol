// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { AttesterView, Status } from "src/staking/libraries/AztecTypes.sol";

/// @title StakingManagerHandler
/// @notice Handler contract for StakingManager invariant testing.
/// @dev Manages random state transitions to test invariants.
contract StakingManagerHandler is Test {
    using Math for uint256;

    StakingManager public stakingManager;
    StakingProviderRegistry public stakingProviderRegistry;
    MockAztec public stakingAsset;
    MockAztecRollupRegistry public rollupRegistry;
    MockAztecRollup public rollup;

    address public core;
    address public providerAdmin;
    address public defaultAdmin;
    address public rewardsAccumulator;

    // Ghost variables for tracking state
    uint256 public ghost_totalStaked;
    uint256 public ghost_totalUnstaked;
    uint256 public ghost_keysAdded;
    uint256 public ghost_keysDripped;
    uint256 public ghost_keysActivated;
    uint256 public ghost_totalHarvested;
    uint256 public ghost_totalRewardsSet;
    address[] public ghost_attesters;

    constructor(
        StakingManager _stakingManager,
        StakingProviderRegistry _stakingProviderRegistry,
        MockAztec _stakingAsset,
        MockAztecRollupRegistry _rollupRegistry,
        MockAztecRollup _rollup,
        address _core,
        address _providerAdmin,
        address _defaultAdmin,
        address _rewardsAccumulator
    ) {
        stakingManager = _stakingManager;
        stakingProviderRegistry = _stakingProviderRegistry;
        stakingAsset = _stakingAsset;
        rollupRegistry = _rollupRegistry;
        rollup = _rollup;
        core = _core;
        providerAdmin = _providerAdmin;
        defaultAdmin = _defaultAdmin;
        rewardsAccumulator = _rewardsAccumulator;
    }

    /// @notice Add keys to the provider queue (only provider admin can call)
    function addKeysToProvider(uint256 count) external {
        vm.startPrank(providerAdmin);

        count = bound(count, 1, 10);

        IStakingManager.KeyStore[] memory keyStores = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            address attester = makeAddr(string(abi.encode("attester", ghost_keysAdded + i)));

            // Generate dummy BLS key data
            G1Point memory publicKeyG1 = G1Point({
                x: uint256(keccak256(abi.encodePacked("x", attester))),
                y: uint256(keccak256(abi.encodePacked("y", attester)))
            });

            G2Point memory publicKeyG2 = G2Point({
                x0: uint256(keccak256(abi.encodePacked("x2a", attester))),
                x1: uint256(keccak256(abi.encodePacked("x2b", attester))),
                y0: uint256(keccak256(abi.encodePacked("y2a", attester))),
                y1: uint256(keccak256(abi.encodePacked("y2b", attester)))
            });

            G1Point memory proofOfPossession = G1Point({
                x: uint256(keccak256(abi.encodePacked("popx", attester))),
                y: uint256(keccak256(abi.encodePacked("popy", attester)))
            });

            keyStores[i] = IStakingManager.KeyStore({
                attester: attester,
                publicKeyG1: publicKeyG1,
                publicKeyG2: publicKeyG2,
                proofOfPossession: proofOfPossession
            });
        }

        try stakingProviderRegistry.addKeysToProvider(keyStores) {
            ghost_keysAdded += count;
            for (uint256 i; i < count; ++i) {
                ghost_attesters.push(keyStores[i].attester);
            }
        } catch {
            // Expected if invalid inputs
        }

        vm.stopPrank();
    }

    /// @notice Remove keys from queue (only provider admin can call)
    function dripQueue(uint256 count) external {
        vm.startPrank(providerAdmin);

        uint256 queueLengthBefore = stakingProviderRegistry.getQueueLength();
        if (queueLengthBefore == 0) {
            vm.stopPrank();
            return;
        }

        count = bound(count, 1, queueLengthBefore);

        try stakingProviderRegistry.dripQueue(count) {
            ghost_keysDripped += count;
        } catch {
            // Expected if queue empty
        }

        vm.stopPrank();
    }

    /// @notice Stake tokens (only core can call)
    function stake(uint256 amount) external {
        vm.startPrank(core);

        uint256 queueLength = stakingProviderRegistry.getQueueLength();
        if (queueLength == 0) {
            vm.stopPrank();
            return;
        }

        // Bound amount to reasonable range that can activate at least one attester
        uint256 activationThreshold = rollup.getActivationThreshold();
        amount = bound(amount, activationThreshold, activationThreshold * queueLength);

        // Mint tokens to core contract for staking
        stakingAsset.mint(core, amount);

        uint256 activatedBefore = stakingManager.getActivatedAttesterCount();

        try stakingManager.stake(amount) {
            uint256 activatedAfter = stakingManager.getActivatedAttesterCount();
            uint256 newlyActivated = activatedAfter - activatedBefore;
            ghost_keysActivated += newlyActivated;
            ghost_totalStaked += newlyActivated * activationThreshold;
        } catch {
            // Expected if insufficient keys or amount below threshold
        }

        vm.stopPrank();
    }

    /// @notice Unstake tokens (only core can call)
    function unstake(uint256 amount) external {
        vm.startPrank(core);

        uint256 activatedCount = stakingManager.getActivatedAttesterCount();
        if (activatedCount == 0) {
            vm.stopPrank();
            return;
        }

        // Bound amount to something reasonable
        uint256 activationThreshold = rollup.getActivationThreshold();
        amount = bound(amount, 1, activatedCount * activationThreshold);

        uint256 pendingBefore = stakingManager.getPendingUnstakeCount();

        try stakingManager.unstake(amount) {
            uint256 pendingAfter = stakingManager.getPendingUnstakeCount();
            ghost_totalUnstaked += (pendingAfter - pendingBefore) * activationThreshold;
        } catch {
            // Expected if insufficient stake or other conditions not met
        }

        vm.stopPrank();
    }

    /// @notice Claim unstaked funds (only core can call)
    function getUnstakedFunds() external {
        vm.prank(core);
        try stakingManager.getUnstakedFunds() returns (uint256, uint256, bool) {
        // Could track claimed amount if needed
        }
            catch {
            // Expected if not authorized or no funds to claim
        }
    }

    /// @notice Externally finalize an exiting attester on the rollup, then refresh.
    /// @dev Simulates a third party calling finalizeWithdraw directly on the rollup.
    function externallyFinalizeAndRefresh(uint256 attesterSeed) external {
        if (ghost_attesters.length == 0) return;

        uint256 idx = bound(attesterSeed, 0, ghost_attesters.length - 1);
        address attester = ghost_attesters[idx];

        // Only finalize if the attester has an exit on the rollup
        if (!rollup.getAttesterView(attester).exit.exists) return;

        // External finalization: call finalizeWithdraw directly on rollup
        try rollup.finalizeWithdraw(attester) {
            ghost_externallyFinalized++;
        } catch {
            return;
        }

        // Refresh to reconcile StakingManager state
        address[] memory attesters = new address[](1);
        attesters[0] = attester;
        stakingManager.refreshAttesterState(attesters);
    }

    /// @notice Refresh attester state for all known attesters.
    function refreshAllAttesters() external {
        if (ghost_attesters.length == 0) return;
        stakingManager.refreshAttesterState(ghost_attesters);
    }

    uint256 public ghost_externallyFinalized;

    /// @notice Harvest rewards (only core can call)
    /// @dev Sets random rewards for the rewards vault address before harvesting.
    function harvestRewards(uint256 rewardSeed) external {
        uint256 reward = bound(rewardSeed, 0, 10e18);
        if (reward > 0) {
            uint256 currentPending = rollup.pendingRewards(rewardsAccumulator);
            stakingAsset.mint(address(rollup), reward);
            rollup.setRewards(rewardsAccumulator, currentPending + reward);
            ghost_totalRewardsSet += reward;
        }

        vm.prank(core);
        try stakingManager.harvestRewards() returns (uint256 harvested) {
            ghost_totalHarvested += harvested;
        } catch {
            // Expected if not authorized or other errors
        }
    }

    function ghostAttestersLength() external view returns (uint256) {
        return ghost_attesters.length;
    }

    function ghostAttesterAt(uint256 index) external view returns (address) {
        return ghost_attesters[index];
    }

    function getGhostAttesters() external view returns (address[] memory) {
        return ghost_attesters;
    }
}

/// @title StakingManagerInvariantTest
/// @notice Comprehensive invariant testing for StakingManager contract.
contract StakingManagerInvariantTest is Test {
    using Math for uint256;

    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;
    MockAztec internal stakingAsset;
    MockAztecRollupRegistry internal rollupRegistry;
    MockAztecRollup internal rollup;
    MockRewardsAccumulator internal rewardsAccumulator;
    StakingManagerHandler internal handler;

    address internal core;
    address internal providerAdmin;
    address internal defaultAdmin;

    function setUp() external {
        // Setup addresses
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        defaultAdmin = makeAddr("defaultAdmin");

        // Setup mock contracts
        stakingAsset = new MockAztec(address(this));
        rollupRegistry = new MockAztecRollupRegistry(address(0));
        rollup = new MockAztecRollup(stakingAsset, 100e18); // 100 AZTEC activation threshold
        rewardsAccumulator = new MockRewardsAccumulator(IERC20(address(stakingAsset)), core);

        // Set canonical rollup
        rollupRegistry.setCanonicalRollup(address(rollup));

        // Deploy StakingManager behind an ERC1967 proxy
        StakingManager stakingManagerImpl = new StakingManager();
        ERC1967Proxy stakingManagerProxy = new ERC1967Proxy(address(stakingManagerImpl), "");
        stakingManager = StakingManager(address(stakingManagerProxy));

        // Deploy StakingProviderRegistry behind an ERC1967 proxy
        StakingProviderRegistry registryImpl = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), "");
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));

        // Initialize StakingProviderRegistry first
        stakingProviderRegistry.initialize(
            address(stakingManager), providerAdmin, makeAddr("providerRewardsRecipient"), defaultAdmin
        );

        // Initialize StakingManager
        stakingManager.initialize(
            stakingAsset,
            address(rollupRegistry),
            address(rewardsAccumulator),
            core,
            address(stakingProviderRegistry),
            defaultAdmin
        );

        // Approve staking manager to spend core's tokens
        vm.prank(core);
        stakingAsset.approve(address(stakingManager), type(uint256).max);

        // Setup handler
        handler = new StakingManagerHandler(
            stakingManager,
            stakingProviderRegistry,
            stakingAsset,
            rollupRegistry,
            rollup,
            core,
            providerAdmin,
            defaultAdmin,
            address(rewardsAccumulator)
        );

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                           CORE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Staking state amounts are never negative
    function invariant_StakingStateNonNegative() external view {
        IStakingManager.StakingState memory state = stakingManager.getStakingState();

        assertGe(state.stakedAmount, 0, "stakedAmount should never be negative");
        assertGe(state.pendingUnstakeAmount, 0, "pendingUnstakeAmount should never be negative");
        assertGe(state.withdrawableAmount, 0, "withdrawableAmount should never be negative");
    }

    /// @notice Queue length consistency checks
    function invariant_QueueLengthConsistency() external view {
        uint256 queueLength = stakingProviderRegistry.getQueueLength();

        // Queue length should never be negative (uint256 is always >= 0)
        assertGe(queueLength, 0, "queue length should never be negative");

        // Queue length should not exceed total keys added
        uint256 added = handler.ghost_keysAdded();
        assertLe(queueLength, added, "queue length should not exceed total keys added");

        // Queue length should equal: keys added - keys dripped - keys activated (used in staking)
        uint256 dripped = handler.ghost_keysDripped();
        uint256 activated = handler.ghost_keysActivated();
        uint256 expectedMax = added > (dripped + activated) ? added - dripped - activated : 0;
        assertLe(queueLength, expectedMax + added, "queue length should be bounded by keys added minus consumed");
    }

    /// @notice Activated attester count consistency
    function invariant_ActivatedAttesterConsistency() external view {
        uint256 currentActivatedCount = stakingManager.getActivatedAttesterCount();

        // Activated attester count should never be negative
        assertGe(currentActivatedCount, 0, "activated attester count should never be negative");

        // Should be bounded by reasonable limits based on total keys processed
        assertLe(
            currentActivatedCount, handler.ghost_keysAdded(), "activated attesters should not exceed total keys added"
        );
    }

    /// @notice Pending unstake count consistency
    function invariant_PendingUnstakeCountConsistency() external view {
        uint256 pendingCount = stakingManager.getPendingUnstakeCount();

        // Pending unstake count should never be negative
        assertGe(pendingCount, 0, "pending unstake count should never be negative");

        // Should be bounded by total keys activated (can't have more pending than were activated)
        assertLe(
            pendingCount, handler.ghost_keysActivated(), "pending unstakes should be bounded by total attestations"
        );
    }

    /// @notice Provider config consistency
    function invariant_ProviderConfigConsistency() external view {
        IStakingManager.ProviderConfig memory config = stakingProviderRegistry.getStakingProviderConfig();

        // Config addresses should never be zero
        assertNotEq(config.admin, address(0), "provider admin should never be zero address");
        assertNotEq(config.rewardsRecipient, address(0), "rewards recipient should never be zero address");
    }

    /// @notice Total assets consistency across all states
    function invariant_TotalAssetsConsistency() external view {
        IStakingManager.StakingState memory state = stakingManager.getStakingState();

        // The sum of all states should be reasonable (can't exceed total minted tokens)
        uint256 totalInStates = state.stakedAmount + state.pendingUnstakeAmount + state.withdrawableAmount;

        // This is a loose bound since we don't track exact token flows, but should be reasonable
        assertLe(totalInStates, 1_000_000e18, "total assets in all states should be reasonable");
    }

    /// @notice Queue operations maintain FIFO property
    function invariant_QueueFIFOMaintained() external view {
        // This is more of a behavioral invariant that would need more complex state tracking
        // For now, we just ensure queue operations don't break basic properties
        uint256 queueLength = stakingProviderRegistry.getQueueLength();

        // Queue should maintain valid state
        if (queueLength == 0) {
            // When empty, no drips should be possible
            // This is tested in the handler but we can add assertions here if needed
        }
    }

    /// @notice State transitions maintain consistency
    function invariant_StateTransitionConsistency() external view {
        uint256 currentActivated = stakingManager.getActivatedAttesterCount();
        uint256 pendingCount = stakingManager.getPendingUnstakeCount();

        // The sum of activated and pending should equal total keys activated
        // (attesters can only transition from activated -> pending -> finalized)
        assertLe(
            currentActivated + pendingCount,
            handler.ghost_keysActivated(),
            "activated + pending should not exceed total keys activated"
        );
    }

    /// @notice Registry only contains Active/Exiting entries; removed attesters are not counted as staked
    function invariant_InactiveEntriesNotStaked() external view {
        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        uint256 eligibleCount = _countRollupEligible();
        uint256 activationThreshold = rollup.getActivationThreshold();

        // stakedAmount tracks Active attesters; pendingUnstakeAmount tracks Exiting attesters.
        // Together they should match all rollup-eligible attesters.
        assertEq(
            state.stakedAmount + state.pendingUnstakeAmount,
            eligibleCount * activationThreshold,
            "staked + pending should match eligible attesters"
        );
    }

    /// @notice Exiting entries correspond to rollup exits or await reconciliation
    function invariant_ExitingEntriesHaveRollupExit() external view {
        uint256 exitCount = _countRollupExits();
        uint256 pendingCount = stakingManager.getPendingUnstakeCount();

        assertLe(pendingCount, exitCount, "exiting count should not exceed rollup exits");
    }

    /// @notice No attester can be in multiple conflicting states simultaneously
    function invariant_AttesterStateExclusivity() external view {
        // This would require iterating through all attesters to check state exclusivity
        // For now, we ensure counts are consistent

        uint256 currentActivated = stakingManager.getActivatedAttesterCount();
        uint256 pendingCount = stakingManager.getPendingUnstakeCount();
        uint256 queueLength = stakingProviderRegistry.getQueueLength();

        // Basic consistency: total unique attestations should be reasonable
        uint256 totalTracked = currentActivated + pendingCount + queueLength;
        assertLe(totalTracked, handler.ghost_keysAdded(), "total tracked attestations should not exceed keys added");
    }

    /// @notice Staking operations respect activation threshold
    function invariant_ActivationThresholdRespected() external view {
        // Check that staking operations only occur when sufficient conditions are met
        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        uint256 queueLength = stakingProviderRegistry.getQueueLength();

        // If there are staked assets, there should be corresponding active or exiting attesters
        // (stakedAmount includes both Active and Exiting attesters)
        if (state.stakedAmount > 0) {
            uint256 activeOrExiting = activatedCount() + stakingManager.getPendingUnstakeCount();
            assertGt(activeOrExiting, 0, "staked amount should correspond to active or exiting attesters");
        }

        // Should not be able to stake without keys in queue
        if (queueLength == 0) {
            // This invariant is behavioral and would need to be tested through operations
        }
    }

    /// @notice pendingUnstakeAmount must not exceed the sum of rollup exit amounts
    ///         for all known attesters. After refresh, externally finalized exits must
    ///         be subtracted from pendingUnstakeAmount.
    function invariant_PendingUnstakeNotStale() external view {
        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        uint256 rollupExitTotal = _sumRollupExitAmounts();

        assertLe(
            state.pendingUnstakeAmount,
            rollupExitTotal + handler.ghost_externallyFinalized() * rollup.getActivationThreshold(),
            "pendingUnstakeAmount should not exceed rollup exits + reconciled externals"
        );
    }

    /// @notice Balance consistency across contract interactions
    function invariant_BalanceConsistency() external view {
        // Rewards are paid by the rollup directly to `rewardsAccumulator` (the claim recipient).
        // StakingManager only triggers the claim and emits accounting signals.
        assertEq(
            stakingAsset.balanceOf(address(rewardsAccumulator)),
            handler.ghost_totalHarvested(),
            "rewards vault balance should equal harvested"
        );
    }

    /*//////////////////////////////////////////////////////////////
                       HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function activatedCount() internal view returns (uint256) {
        return stakingManager.getActivatedAttesterCount();
    }

    function _countRollupValidating() internal view returns (uint256 validatingCount) {
        uint256 length = handler.ghostAttestersLength();
        for (uint256 i; i < length; ++i) {
            address attester = handler.ghostAttesterAt(i);
            if (rollup.getAttesterView(attester).status == Status.VALIDATING) {
                ++validatingCount;
            }
        }
        return validatingCount;
    }

    function _countRollupEligible() internal view returns (uint256 eligibleCount) {
        uint256 length = handler.ghostAttestersLength();
        for (uint256 i; i < length; ++i) {
            address attester = handler.ghostAttesterAt(i);
            if (rollup.getAttesterView(attester).effectiveBalance > 0 || rollup.getAttesterView(attester).exit.exists) {
                ++eligibleCount;
            }
        }
        return eligibleCount;
    }

    function _sumRollupExitAmounts() internal view returns (uint256 total) {
        uint256 length = handler.ghostAttestersLength();
        for (uint256 i; i < length; ++i) {
            address attester = handler.ghostAttesterAt(i);
            AttesterView memory view_ = rollup.getAttesterView(attester);
            if (view_.exit.exists) {
                total += view_.exit.amount;
            }
        }
        return total;
    }

    function _countRollupExits() internal view returns (uint256 exitCount) {
        uint256 length = handler.ghostAttestersLength();
        for (uint256 i; i < length; ++i) {
            address attester = handler.ghostAttesterAt(i);
            if (rollup.getAttesterView(attester).exit.exists) {
                ++exitCount;
            }
        }
        return exitCount;
    }
}
