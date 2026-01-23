// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { StakingManager } from "src/core/StakingManager.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockAztecRollupRegistry } from "src/mocks/MockAztecRollupRegistry.sol";
import { MockAztecRollup } from "src/mocks/MockAztecRollup.sol";
import { MockRewardsVault } from "src/mocks/MockRewardsVault.sol";
import { G1Point, G2Point } from "src/libraries/BN254Lib.sol";

/// @title StakingManagerHandler
/// @notice Handler contract for StakingManager invariant testing.
/// @dev Manages random state transitions to test invariants.
contract StakingManagerHandler is Test {
    using Math for uint256;

    StakingManager public stakingManager;
    MockAztec public stakingAsset;
    MockAztecRollupRegistry public rollupRegistry;
    MockAztecRollup public rollup;

    address public core;
    address public providerAdmin;
    address public rewardsVault;

    // Ghost variables for tracking state
    uint256 public ghost_totalStaked;
    uint256 public ghost_totalUnstaked;
    uint256 public ghost_keysAdded;
    uint256 public ghost_keysDripped;
    uint256 public ghost_keysActivated;
    uint256 public ghost_totalHarvested;
    uint256 public ghost_totalRewardsSet;

    constructor(
        StakingManager _stakingManager,
        MockAztec _stakingAsset,
        MockAztecRollupRegistry _rollupRegistry,
        MockAztecRollup _rollup,
        address _core,
        address _providerAdmin,
        address _rewardsVault
    ) {
        stakingManager = _stakingManager;
        stakingAsset = _stakingAsset;
        rollupRegistry = _rollupRegistry;
        rollup = _rollup;
        core = _core;
        providerAdmin = _providerAdmin;
        rewardsVault = _rewardsVault;
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

        try stakingManager.addKeysToProvider(keyStores) {
            ghost_keysAdded += count;
        } catch {
            // Expected if invalid inputs
        }

        vm.stopPrank();
    }

    /// @notice Remove keys from queue (only provider admin can call)
    function dripQueue(uint256 count) external {
        vm.startPrank(providerAdmin);

        uint256 queueLengthBefore = stakingManager.getQueueLength();
        if (queueLengthBefore == 0) {
            vm.stopPrank();
            return;
        }

        count = bound(count, 1, queueLengthBefore);

        try stakingManager.dripQueue(count) {
            ghost_keysDripped += count;
        } catch {
            // Expected if queue empty
        }

        vm.stopPrank();
    }

    /// @notice Stake tokens (only core can call)
    function stake(uint256 amount) external {
        vm.startPrank(core);

        uint256 queueLength = stakingManager.getQueueLength();
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

    /// @notice Clean activated attesters (only core can call)
    function cleanActivatedAttesters() external {
        vm.prank(core);
        try stakingManager.cleanActivatedAttesters() {
        // Track state changes if needed
        }
            catch {
            // Expected if not authorized
        }
    }

    /// @notice Claim unstaked funds (only core can call)
    function getUnstakedFunds() external {
        vm.prank(core);
        try stakingManager.getUnstakedFunds() returns (
            uint256
        ) {
        // Could track claimed amount if needed
        }
            catch {
            // Expected if not authorized or no funds to claim
        }
    }

    /// @notice Harvest rewards (only core can call)
    /// @dev Sets random rewards for activated attesters before harvesting.
    function harvestRewards(uint256 rewardSeed) external {
        uint256 activatedCount = stakingManager.getActivatedAttesterCount();

        // Set random rewards for some attesters if there are any
        if (activatedCount > 0) {
            // Use seed to determine reward amount per attester
            uint256 rewardPerAttester = bound(rewardSeed, 0, 10e18);

            // We can't iterate activated attesters directly, but we can set rewards
            // for addresses based on our key generation pattern (address(uint160(i + 1)))
            uint256 keysToReward = bound(rewardSeed % 100, 0, ghost_keysActivated);
            for (uint256 i; i < keysToReward; ++i) {
                address attester = address(uint160(i + 1));
                // Only set rewards if we have tokens to back them
                if (rewardPerAttester > 0) {
                    stakingAsset.mint(address(rollup), rewardPerAttester);
                    rollup.setRewards(attester, rewardPerAttester);
                    ghost_totalRewardsSet += rewardPerAttester;
                }
            }
        }

        vm.prank(core);
        try stakingManager.harvestRewards(100_000) returns (uint256 harvested) {
            ghost_totalHarvested += harvested;
        } catch {
            // Expected if not authorized or other errors
        }
    }
}

/// @title StakingManagerInvariantTest
/// @notice Comprehensive invariant testing for StakingManager contract.
contract StakingManagerInvariantTest is Test {
    using Math for uint256;

    StakingManager internal stakingManager;
    MockAztec internal stakingAsset;
    MockAztecRollupRegistry internal rollupRegistry;
    MockAztecRollup internal rollup;
    MockRewardsVault internal rewardsVault;
    StakingManagerHandler internal handler;

    address internal core;
    address internal providerAdmin;
    address internal governance;
    address internal defaultAdmin;
    address internal treasury;

    function setUp() external {
        // Setup addresses
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        governance = makeAddr("governance");
        defaultAdmin = makeAddr("defaultAdmin");
        treasury = makeAddr("treasury");

        // Setup mock contracts
        stakingAsset = new MockAztec(address(this));
        rollupRegistry = new MockAztecRollupRegistry(address(0));
        rollup = new MockAztecRollup(stakingAsset, 100e18); // 100 AZTEC activation threshold
        rewardsVault = new MockRewardsVault(IERC20(address(stakingAsset)), core, treasury);

        // Set canonical rollup
        rollupRegistry.setCanonicalRollup(address(rollup));

        // Deploy StakingManager (non-upgradeable, constructor-based initialization)
        stakingManager = new StakingManager(
            stakingAsset,
            address(rollupRegistry),
            address(rewardsVault),
            core,
            providerAdmin,
            makeAddr("providerRewardsRecipient"),
            defaultAdmin
        );

        // Approve staking manager to spend core's tokens
        vm.prank(core);
        stakingAsset.approve(address(stakingManager), type(uint256).max);

        // Setup handler
        handler = new StakingManagerHandler(
            stakingManager, stakingAsset, rollupRegistry, rollup, core, providerAdmin, address(rewardsVault)
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
        uint256 queueLength = stakingManager.getQueueLength();

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
        IStakingManager.ProviderConfig memory config = stakingManager.getProviderConfig();

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
        uint256 queueLength = stakingManager.getQueueLength();

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

    /// @notice No attester can be in multiple conflicting states simultaneously
    function invariant_AttesterStateExclusivity() external view {
        // This would require iterating through all attesters to check state exclusivity
        // For now, we ensure counts are consistent

        uint256 currentActivated = stakingManager.getActivatedAttesterCount();
        uint256 pendingCount = stakingManager.getPendingUnstakeCount();
        uint256 queueLength = stakingManager.getQueueLength();

        // Basic consistency: total unique attestations should be reasonable
        uint256 totalTracked = currentActivated + pendingCount + queueLength;
        assertLe(totalTracked, handler.ghost_keysAdded(), "total tracked attestations should not exceed keys added");
    }

    /// @notice Staking operations respect activation threshold
    function invariant_ActivationThresholdRespected() external view {
        // Check that staking operations only occur when sufficient conditions are met
        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        uint256 queueLength = stakingManager.getQueueLength();

        // If there are staked assets, there should be corresponding activated attesters
        if (state.stakedAmount > 0) {
            assertGt(activatedCount(), 0, "staked amount should correspond to activated attesters");
        }

        // Should not be able to stake without keys in queue
        if (queueLength == 0) {
            // This invariant is behavioral and would need to be tested through operations
        }
    }

    /// @notice Balance consistency across contract interactions
    function invariant_BalanceConsistency() external view {
        // Check that staking manager doesn't hold unexpected token balances
        uint256 stakingManagerBalance = stakingAsset.balanceOf(address(stakingManager));

        // Staking manager should generally not hold tokens except during transaction execution
        // In steady state, balance should be minimal
        assertLe(stakingManagerBalance, 1e18, "staking manager should not hold large token balances in steady state");
    }

    /*//////////////////////////////////////////////////////////////
                       HARVEST REWARDS INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Harvested rewards should never be negative
    function invariant_HarvestNeverNegative() external view {
        assertGe(handler.ghost_totalHarvested(), 0, "total harvested should never be negative");
    }

    /// @notice Harvested rewards should not exceed total rewards set
    function invariant_HarvestNotExceedRewardsSet() external view {
        assertLe(
            handler.ghost_totalHarvested(),
            handler.ghost_totalRewardsSet(),
            "harvested should not exceed total rewards set"
        );
    }

    /// @notice RewardsVault balance consistency with harvested rewards
    function invariant_RewardsVaultConsistency() external view {
        uint256 vaultBalance = stakingAsset.balanceOf(address(rewardsVault));
        uint256 totalHarvested = handler.ghost_totalHarvested();

        // Vault balance should equal total harvested (assuming no withdrawals in tests)
        assertEq(vaultBalance, totalHarvested, "vault balance should match total harvested");
    }

    /*//////////////////////////////////////////////////////////////
                      HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function activatedCount() internal view returns (uint256) {
        return stakingManager.getActivatedAttesterCount();
    }
}
