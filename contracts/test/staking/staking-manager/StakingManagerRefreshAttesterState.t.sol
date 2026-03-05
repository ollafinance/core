// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Vm } from "@forge-std/Test.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MaliciousAztecRollup } from "src/staking/mocks/MaliciousAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

contract StakingManagerRefreshAttesterStateTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                    REFRESH ATTESTER STATE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone can call refreshAttesterState() - it has no access control.
    function test_RefreshAttesterState_PermissionlessAccess() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Call refreshAttesterState() from a random address (not core, not operator, not admin)
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending unstake should be cleared");
    }

    /// @notice When there are no exiting attesters, refreshAttesterState() is a no-op.
    function test_RefreshAttesterState_NoOp_WhenNoExitableAttesters() external {
        // No attesters registered or staked at all — should not revert
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // With staked attesters but none unstaking — should not revert
        _setupStakedAttester();
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getActivatedAttesterCount(), 1, "active count should be unchanged");
    }

    /// @notice refreshAttesterState() tracks the finalized amount in _pendingClaimAmount,
    ///         which is then returned as exitAmount by getUnstakedFunds().
    function test_RefreshAttesterState_TracksPendingClaimAmount() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // getUnstakedFunds should report exitAmount equal to what was finalized
        vm.prank(core);
        (, uint256 exitAmount,) = stakingManager.getUnstakedFunds();

        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exitAmount should match the finalized amount");
    }

    /// @notice Multiple calls to refreshAttesterState() accumulate _pendingClaimAmount
    ///         until getUnstakedFunds() drains it.
    function test_RefreshAttesterState_AccumulatesAcrossMultipleCalls() external {
        _setupMultipleStakedAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        // Unstake both attesters
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        // Make only the second attester exitable initially
        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        // First refreshAttesterState: only attester[1] is exitable
        stakingManager.refreshAttesterState(_attesterAddresses(2));
        vm.prank(core);
        (, uint256 firstExitAmount,) = stakingManager.getUnstakedFunds();
        assertEq(firstExitAmount, ACTIVATION_THRESHOLD, "first call should finalize one attester");

        // Advance time so attester[0] becomes exitable
        vm.warp(block.timestamp + 2 days);

        // Second refreshAttesterState: attester[0] now exitable
        stakingManager.refreshAttesterState(_attesterAddresses(2));
        vm.prank(core);
        (, uint256 secondExitAmount,) = stakingManager.getUnstakedFunds();
        assertEq(secondExitAmount, ACTIVATION_THRESHOLD, "second call should finalize remaining attester");
    }

    /// @notice getUnstakedFunds() returns exitAmount matching _pendingClaimAmount and resets it to 0.
    ///         A subsequent call to getUnstakedFunds() should return exitAmount=0.
    function test_GetUnstakedFunds_ReturnsExitAmountAndResetsIt() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        stakingManager.refreshAttesterState(_attesterAddresses(1));

        // First getUnstakedFunds: should return exitAmount matching finalized amount
        vm.prank(core);
        (uint256 received, uint256 exitAmount, bool hasRemainingExits) = stakingManager.getUnstakedFunds();

        assertEq(exitAmount, ACTIVATION_THRESHOLD, "first call exitAmount should match finalized amount");
        assertEq(received, ACTIVATION_THRESHOLD, "first call received should include finalized tokens");
        assertFalse(hasRemainingExits, "no remaining exits after full finalization");

        // Second getUnstakedFunds: _pendingClaimAmount was reset, so exitAmount should be 0
        vm.prank(core);
        (uint256 receivedSecond, uint256 exitAmountSecond,) = stakingManager.getUnstakedFunds();

        assertEq(exitAmountSecond, 0, "second call exitAmount should be 0 after reset");
        assertEq(receivedSecond, 0, "second call received should be 0 with no balance remaining");
    }

    /// @notice Tokens sent directly to StakingManager (donations) are swept by getUnstakedFunds()
    ///         as `received` but are NOT counted as `exitAmount`.
    function test_GetUnstakedFunds_DonationSweptAsReceivedNotExitAmount() external {
        uint256 donationAmount = 50 ether;

        // Mint tokens to alice and have alice send them directly to StakingManager (donation)
        aztec.mint(alice, donationAmount);
        vm.prank(alice);
        aztec.transfer(address(stakingManager), donationAmount);

        assertEq(aztec.balanceOf(address(stakingManager)), donationAmount, "manager should hold donated tokens");

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        // getUnstakedFunds should sweep the donation as `received` but exitAmount should be 0
        vm.prank(core);
        (uint256 received, uint256 exitAmount, bool hasRemainingExits) = stakingManager.getUnstakedFunds();

        assertEq(received, donationAmount, "received should include donated tokens");
        assertEq(exitAmount, 0, "exitAmount should be 0 since no exits were finalized");
        assertFalse(hasRemainingExits, "no remaining exits");
        assertEq(aztec.balanceOf(core), coreBalanceBefore + donationAmount, "core should receive donated tokens");
        assertEq(aztec.balanceOf(address(stakingManager)), 0, "manager should have zero balance after sweep");
    }

    /*//////////////////////////////////////////////////////////////
            EXTERNALLY FINALIZED ACTIVE ATTESTER RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice An active attester that was externally fully exited (zero balance, no exit record)
    ///         should be removed during refreshAttesterState.
    function test_RefreshAttesterState_RemovesExternallyFinalizedActiveAttester() external {
        _setupStakedAttester();
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "should have 1 active attester");

        // Simulate external full exit: rollup clears all state for this attester
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        rollup.clearAttester(keys[0].attester);

        // Refresh should detect zero balance + no exit and remove the attester
        stakingManager.refreshAttesterState(_attesterAddresses(1));

        assertEq(stakingManager.getActivatedAttesterCount(), 0, "active count should be 0 after removal");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending unstake count should be 0 after removal");
    }

    /// @notice When an externally finalized active attester is removed, the aggregate stakedAmount
    ///         should be decremented by the attester's cached balance.
    function test_RefreshAttesterState_ExternallyFinalizedUpdatesAggregateState() external {
        _setupMultipleStakedAttesters(2);
        assertEq(stakingManager.getActivatedAttesterCount(), 2, "should have 2 active attesters");

        // Externally finalize only the first attester
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        rollup.clearAttester(keys[0].attester);

        stakingManager.refreshAttesterState(_attesterAddresses(2));

        assertEq(stakingManager.getActivatedAttesterCount(), 1, "active count should be 1");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending unstake count should be 0");
    }

    /*//////////////////////////////////////////////////////////////
                REFRESH ATTESTER STATE REENTRANCY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice refreshAttesterState() is protected by nonReentrant. Re-entering via the rollup's
    ///         finalizeWithdraw() callback reverts with ReentrancyGuardReentrantCall.
    function test_RevertWhen_RefreshAttesterState_Reentrancy() external {
        // Deploy a malicious rollup that re-enters during finalizeWithdraw
        MaliciousAztecRollup maliciousRollup = new MaliciousAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        MockAztecRollupRegistry maliciousRegistry = new MockAztecRollupRegistry(address(maliciousRollup));
        MockRewardsAccumulator maliciousRewardsAccumulator = new MockRewardsAccumulator(IERC20(address(aztec)), core);

        // Deploy a fresh StakingManager wired to the malicious rollup
        StakingManager maliciousSM = StakingManager(address(new ERC1967Proxy(address(new StakingManager()), "")));

        StakingProviderRegistry maliciousRegistry2 =
            StakingProviderRegistry(address(new ERC1967Proxy(address(new StakingProviderRegistry()), "")));
        maliciousRegistry2.initialize(address(maliciousSM), providerAdmin, providerAdmin, defaultAdmin);

        maliciousSM.initialize(
            IERC20(address(aztec)),
            address(maliciousRegistry),
            address(maliciousRewardsAccumulator),
            core,
            address(maliciousRegistry2),
            defaultAdmin
        );

        // Stake one attester
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        maliciousRegistry2.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(maliciousSM), ACTIVATION_THRESHOLD);
        maliciousSM.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // Unstake to put attester into exiting state
        vm.prank(core);
        maliciousSM.unstake(ACTIVATION_THRESHOLD);

        // Configure the malicious rollup to re-enter refreshAttesterState during finalizeWithdraw
        address[] memory reentrancyAttesters = _attesterAddresses(1);
        maliciousRollup.setReentry(
            address(maliciousSM), abi.encodeCall(maliciousSM.refreshAttesterState, (reentrancyAttesters))
        );
        maliciousRollup.setReenterOnFinalizeWithdraw(true);

        // The reentrancy attempt should revert
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        maliciousSM.refreshAttesterState(reentrancyAttesters);
    }
}
