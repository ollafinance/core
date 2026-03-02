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

contract StakingManagerFinalizeExitsTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
                        FINALIZE EXITS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone can call finalizeExits() - it has no access control.
    function test_FinalizeExits_PermissionlessAccess() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Call finalizeExits() from a random address (not core, not operator, not admin)
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        uint256 finalized = stakingManager.finalizeExits();

        assertEq(finalized, ACTIVATION_THRESHOLD, "random caller should be able to finalize exits");
        assertEq(stakingManager.getPendingUnstakeCount(), 0, "pending unstake should be cleared");
    }

    /// @notice When there are no exiting attesters, finalizeExits() returns 0.
    function test_FinalizeExits_ReturnsZero_WhenNoExitableAttesters() external {
        // No attesters registered or staked at all
        uint256 finalized = stakingManager.finalizeExits();
        assertEq(finalized, 0, "should return 0 when no attesters exist");

        // With staked attesters but none unstaking
        _setupStakedAttester();
        finalized = stakingManager.finalizeExits();
        assertEq(finalized, 0, "should return 0 when no attesters are exiting");
    }

    /// @notice finalizeExits() tracks the finalized amount in _pendingClaimAmount,
    ///         which is then returned as exitAmount by getUnstakedFunds().
    function test_FinalizeExits_TracksPendingClaimAmount() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        uint256 finalized = stakingManager.finalizeExits();
        assertEq(finalized, ACTIVATION_THRESHOLD, "finalized amount should match staked amount");

        // getUnstakedFunds should report exitAmount equal to what was finalized
        vm.prank(core);
        (, uint256 exitAmount,) = stakingManager.getUnstakedFunds();

        assertEq(exitAmount, ACTIVATION_THRESHOLD, "exitAmount should match the finalized amount");
    }

    /// @notice Multiple calls to finalizeExits() accumulate _pendingClaimAmount
    ///         until getUnstakedFunds() drains it.
    function test_FinalizeExits_AccumulatesAcrossMultipleCalls() external {
        _setupMultipleStakedAttesters(2);
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);

        // Unstake both attesters
        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        // Make only the second attester exitable initially
        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        // First finalizeExits: only attester[1] is exitable
        uint256 firstFinalized = stakingManager.finalizeExits();
        assertEq(firstFinalized, ACTIVATION_THRESHOLD, "first call should finalize one attester");

        // Advance time so attester[0] becomes exitable
        vm.warp(block.timestamp + 2 days);

        // Second finalizeExits: attester[0] now exitable
        uint256 secondFinalized = stakingManager.finalizeExits();
        assertEq(secondFinalized, ACTIVATION_THRESHOLD, "second call should finalize remaining attester");

        // getUnstakedFunds should report accumulated exitAmount from both calls
        vm.prank(core);
        (, uint256 exitAmount,) = stakingManager.getUnstakedFunds();

        assertEq(
            exitAmount, ACTIVATION_THRESHOLD * 2, "exitAmount should accumulate across multiple finalizeExits calls"
        );
    }

    /// @notice getUnstakedFunds() returns exitAmount matching _pendingClaimAmount and resets it to 0.
    ///         A subsequent call to getUnstakedFunds() should return exitAmount=0.
    function test_GetUnstakedFunds_ReturnsExitAmountAndResetsIt() external {
        _setupStakedAttester();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        stakingManager.finalizeExits();

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
                    FINALIZE EXITS REENTRANCY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice finalizeExits() is protected by nonReentrant. Re-entering via the rollup's
    ///         finalizeWithdraw() callback reverts with ReentrancyGuardReentrantCall.
    function test_RevertWhen_FinalizeExits_Reentrancy() external {
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

        // Configure the malicious rollup to re-enter finalizeExits during finalizeWithdraw
        maliciousRollup.setReentry(address(maliciousSM), abi.encodeCall(maliciousSM.finalizeExits, ()));
        maliciousRollup.setReenterOnFinalizeWithdraw(true);

        // The reentrancy attempt should revert
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        maliciousSM.finalizeExits();
    }
}
