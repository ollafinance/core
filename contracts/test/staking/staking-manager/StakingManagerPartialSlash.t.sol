// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { Exit } from "src/staking/libraries/AztecTypes.sol";

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";

/// @title StakingManagerPartialSlashTest
/// @notice Verifies that partial slashing (zombie exits with reduced amounts) is correctly
///         tracked by the StakingManager, including slashingDelta accounting and fund recovery.
contract StakingManagerPartialSlashTest is StakingManagerBaseTest {
    /*//////////////////////////////////////////////////////////////
     TEST 1: PARTIAL SLASH - SLASHING DELTA EQUALS LOST AMOUNT
    //////////////////////////////////////////////////////////////*/

    /// @notice A partial slash creates a zombie exit with a reduced amount. After refresh,
    ///         the slashingDelta should equal the difference between the original stake and
    ///         the reduced exit amount.
    function test_PartialSlash_SlashingDeltaEqualsLostAmount() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);
        address attester = attesters[0];

        // Original stake = ACTIVATION_THRESHOLD (100 ether)
        // Slash 30%: zombie exit with 70 ether
        uint256 slashedAmount = 70 ether;
        uint256 expectedSlashingDelta = ACTIVATION_THRESHOLD - slashedAmount;

        rollup.setExternalExit(attester, slashedAmount, block.timestamp);

        IStakingManager.StakingState memory stateBefore = stakingManager.getStakingState();
        assertEq(stateBefore.slashingDelta, 0, "pre: slashingDelta should be 0");

        // Refresh detects the zombie exit and accounts for the slash
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory stateAfter = stakingManager.getStakingState();
        assertEq(stateAfter.slashingDelta, expectedSlashingDelta, "slashingDelta should equal lost amount (30 ether)");

        // Funds are claimable at the reduced amount
        vm.prank(core);
        (uint256 received, uint256 exitAmount,) = stakingManager.getUnstakedFunds();
        assertEq(received, slashedAmount, "received should equal slashed exit amount");
        assertEq(exitAmount, slashedAmount, "exitAmount should equal slashed exit amount");
    }

    /*//////////////////////////////////////////////////////////////
     TEST 2: MULTI-ATTESTER PARTIAL SLASH - CUMULATIVE DELTA
    //////////////////////////////////////////////////////////////*/

    /// @notice Multiple attesters are partially slashed. The cumulative slashingDelta
    ///         should be the sum of all individual slashing losses.
    function test_MultiAttester_PartialSlash_CumulativeDelta() external {
        uint256 numAttesters = 3;
        _setupMultipleStakedAttesters(numAttesters);
        address[] memory attesters = _attesterAddresses(numAttesters);

        // Slash each attester by different amounts:
        // attester[0]: 100 ether staked, slash to 80 (lose 20)
        // attester[1]: 100 ether staked, slash to 50 (lose 50)
        // attester[2]: 100 ether staked, slash to 90 (lose 10)
        uint256[] memory exitAmounts = new uint256[](3);
        exitAmounts[0] = 80 ether;
        exitAmounts[1] = 50 ether;
        exitAmounts[2] = 90 ether;
        uint256 expectedTotalSlash = (100 ether - 80 ether) + (100 ether - 50 ether) + (100 ether - 90 ether); // 80

        for (uint256 i; i < numAttesters; ++i) {
            rollup.setExternalExit(attesters[i], exitAmounts[i], block.timestamp);
        }

        // Refresh all attesters
        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.slashingDelta, expectedTotalSlash, "cumulative slashingDelta should be sum of all losses");

        // stakedAmount should be 0 (all attesters exited)
        assertEq(state.stakedAmount, 0, "stakedAmount should be 0 after all exits");

        // All reduced amounts are claimable
        vm.prank(core);
        (uint256 received,,) = stakingManager.getUnstakedFunds();
        uint256 expectedReceived = 80 ether + 50 ether + 90 ether;
        assertEq(received, expectedReceived, "received should equal sum of reduced exit amounts");
    }

    /*//////////////////////////////////////////////////////////////
     TEST 3: TOTAL SLASH (EXIT AMOUNT = 0)
    //////////////////////////////////////////////////////////////*/

    /// @notice A total slash (exit amount = 0) should result in the full stake being lost.
    ///         The slashingDelta equals the full original stake, and no funds are claimable.
    function test_TotalSlash_ExitAmountZero() external {
        _setupStakedAttester();
        address[] memory attesters = _attesterAddresses(1);
        address attester = attesters[0];

        // Total slash: zombie exit with 0 amount
        rollup.setExternalExit(attester, 0, block.timestamp);

        stakingManager.refreshAttesterState(attesters);

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.slashingDelta, ACTIVATION_THRESHOLD, "slashingDelta should equal full stake");
        assertEq(state.stakedAmount, 0, "stakedAmount should be 0");

        // No funds claimable
        vm.prank(core);
        (uint256 received, uint256 exitAmount, bool hasRemainingExits) = stakingManager.getUnstakedFunds();
        assertEq(received, 0, "received should be 0 for total slash");
        assertEq(exitAmount, 0, "exitAmount should be 0 for total slash");
        assertFalse(hasRemainingExits, "no remaining exits");
    }
}
