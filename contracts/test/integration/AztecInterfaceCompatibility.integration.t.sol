// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IAztecRollup as OllaOverrideIStaking } from "src/staking/interfaces/IAztecRollup.sol";
import { IStaking, IStakingCore } from "@az/core/interfaces/IStaking.sol";
import { IRollup } from "@az/core/interfaces/IRollup.sol";
import {
    IAztecRollupRegistry as OllaOverrideIAztecRollupRegistry
} from "src/staking/interfaces/IAztecRollupRegistry.sol";
import {
    IAztecRewardDistributor as OllaOverrideIAztecRewardDistributor
} from "src/staking/interfaces/IAztecRewardDistributor.sol";
import { IRegistry } from "@az/governance/interfaces/IRegistry.sol";
import { G1Point as OllaOverrideG1Point, G2Point as OllaOverrideG2Point } from "src/staking/libraries/BN254Lib.sol";
import { G1Point, G2Point } from "@az/shared/libraries/BN254Lib.sol";

contract AztecInterfaceCompatibilityTest is Test {
    /*//////////////////////////////////////////////////////////////
                                IAztecRollup
    //////////////////////////////////////////////////////////////*/
    function test_Conformance_DepositSignature() public pure {
        bytes4 expectedSelector = IStakingCore.deposit.selector;
        bytes4 actualSelector = OllaOverrideIStaking.deposit.selector;

        assertEq(expectedSelector, actualSelector, "Deposit selector mismatch");
    }

    function test_Conformance_InitiateWithdrawSignature() public pure {
        bytes4 expectedSelector = IStakingCore.initiateWithdraw.selector;
        bytes4 actualSelector = OllaOverrideIStaking.initiateWithdraw.selector;

        assertEq(expectedSelector, actualSelector, "InitiateWithdraw selector mismatch");
    }

    function test_Conformance_FinalizeWithdrawSignature() public pure {
        bytes4 expectedSelector = IStakingCore.finalizeWithdraw.selector;
        bytes4 actualSelector = OllaOverrideIStaking.finalizeWithdraw.selector;

        assertEq(expectedSelector, actualSelector, "FinalizeWithdraw selector mismatch");
    }

    function test_Conformance_GetActivationThresholdSignature() public pure {
        bytes4 expectedSelector = IStaking.getActivationThreshold.selector;
        bytes4 actualSelector = OllaOverrideIStaking.getActivationThreshold.selector;

        assertEq(expectedSelector, actualSelector, "GetActivationThreshold selector mismatch");
    }

    function test_Conformance_GetAttesterViewSignature() public pure {
        bytes4 expectedSelector = IStaking.getAttesterView.selector;
        bytes4 actualSelector = OllaOverrideIStaking.getAttesterView.selector;

        assertEq(expectedSelector, actualSelector, "GetAttesterView selector mismatch");
    }

    function test_Conformance_GetSequencerRewardsSignature() public pure {
        bytes4 expectedSelector = IRollup.getSequencerRewards.selector;
        bytes4 actualSelector = OllaOverrideIStaking.getSequencerRewards.selector;

        assertEq(expectedSelector, actualSelector, "GetSequencerRewards selector mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                          BN254 Struct Compatibility
    //////////////////////////////////////////////////////////////*/

    function test_BN254StructCompatibility() public pure {
        // Create points using our custom types
        OllaOverrideG1Point memory g1 = OllaOverrideG1Point({ x: 1, y: 2 });
        OllaOverrideG2Point memory g2 = OllaOverrideG2Point({ x0: 1, x1: 2, y0: 3, y1: 4 });

        // Create points using Aztec's types
        G1Point memory azG1 = G1Point({ x: 1, y: 2 });
        G2Point memory azG2 = G2Point({ x0: 1, x1: 2, y0: 3, y1: 4 });
        // Verify ABI encoding is identical
        bytes memory encodedCustom = abi.encode(g1, g2);
        bytes memory encodedAztec = abi.encode(azG1, azG2);

        assertEq(encodedCustom, encodedAztec, "BN254 struct encoding mismatch");
    }

    function test_Conformance_GetEntryQueueLengthSignature() public pure {
        bytes4 expectedSelector = IStaking.getEntryQueueLength.selector;
        bytes4 actualSelector = OllaOverrideIStaking.getEntryQueueLength.selector;

        assertEq(expectedSelector, actualSelector, "GetEntryQueueLength selector mismatch");
    }

    function test_Conformance_GetEntryQueueAtSignature() public pure {
        bytes4 expectedSelector = IStaking.getEntryQueueAt.selector;
        bytes4 actualSelector = OllaOverrideIStaking.getEntryQueueAt.selector;

        assertEq(expectedSelector, actualSelector, "GetEntryQueueAt selector mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                                IAztecRollupRegistry
    //////////////////////////////////////////////////////////////*/
    function test_Conformance_GetCanonicalRollupSignature() public pure {
        bytes4 expectedSelector = IRegistry.getCanonicalRollup.selector;
        bytes4 actualSelector = OllaOverrideIAztecRollupRegistry.getCanonicalRollup.selector;

        assertEq(expectedSelector, actualSelector, "GetCanonicalRollup selector mismatch");
    }

    function test_Conformance_GetGovernanceSignature() public pure {
        bytes4 expectedSelector = IRegistry.getGovernance.selector;
        bytes4 actualSelector = OllaOverrideIAztecRollupRegistry.getGovernance.selector;

        assertEq(expectedSelector, actualSelector, "GetGovernance selector mismatch");
    }

    function test_Conformance_GetRewardDistributorSignature() public pure {
        bytes4 expectedSelector = IRegistry.getRewardDistributor.selector;
        bytes4 actualSelector = OllaOverrideIAztecRollupRegistry.getRewardDistributor.selector;

        assertEq(expectedSelector, actualSelector, "GetRewardDistributor selector mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                              IAztecRewardDistributor
    //////////////////////////////////////////////////////////////*/

    function test_Conformance_RewardDistributorAssetSignature() public pure {
        bytes4 expectedSelector = bytes4(keccak256("ASSET()"));
        bytes4 actualSelector = OllaOverrideIAztecRewardDistributor.ASSET.selector;

        assertEq(expectedSelector, actualSelector, "RewardDistributor ASSET selector mismatch");
    }
}
