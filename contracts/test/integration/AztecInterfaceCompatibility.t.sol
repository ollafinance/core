// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IAztecStaking } from "src/interfaces/IAztecStaking.sol";
import { IStaking, IStakingCore } from "@az/core/interfaces/IStaking.sol";
import { G1Point, G2Point } from "src/libraries/BN254Lib.sol";
import { G1Point as AzG1Point, G2Point as AzG2Point } from "@az/shared/libraries/BN254Lib.sol";

contract AztecInterfaceCompatibilityTest is Test {
    function test_Conformance_DepositSignature() public {
        bytes4 expectedSelector = IStakingCore.deposit.selector;
        bytes4 actualSelector = IAztecStaking.deposit.selector;

        assertEq(expectedSelector, actualSelector, "Deposit selector mismatch");
    }

    function test_Conformance_InitiateWithdrawSignature() public {
        bytes4 expectedSelector = IStakingCore.initiateWithdraw.selector;
        bytes4 actualSelector = IAztecStaking.initiateWithdraw.selector;

        assertEq(expectedSelector, actualSelector, "InitiateWithdraw selector mismatch");
    }

    function test_Conformance_FinalizeWithdrawSignature() public {
        bytes4 expectedSelector = IStakingCore.finalizeWithdraw.selector;
        bytes4 actualSelector = IAztecStaking.finalizeWithdraw.selector;

        assertEq(expectedSelector, actualSelector, "FinalizeWithdraw selector mismatch");
    }

    function test_Conformance_GetActivationThresholdSignature() public {
        bytes4 expectedSelector = IStaking.getActivationThreshold.selector;
        bytes4 actualSelector = IAztecStaking.getActivationThreshold.selector;

        assertEq(expectedSelector, actualSelector, "GetActivationThreshold selector mismatch");
    }

    function test_BN254StructCompatibility() public {
        // Create points using our custom types
        G1Point memory g1 = G1Point({ x: 1, y: 2 });
        G2Point memory g2 = G2Point({ x0: 1, x1: 2, y0: 3, y1: 4 });

        // Create points using Aztec's types
        AzG1Point memory azG1 = AzG1Point({ x: 1, y: 2 });
        AzG2Point memory azG2 = AzG2Point({ x0: 1, x1: 2, y0: 3, y1: 4 });

        // Verify ABI encoding is identical
        bytes memory encodedCustom = abi.encode(g1, g2);
        bytes memory encodedAztec = abi.encode(azG1, azG2);

        assertEq(encodedCustom, encodedAztec, "BN254 struct encoding mismatch");
    }

    function test_FunctionSignatureBytes() public {
        bytes32 depositSig = keccak256(
            "deposit(address,address,(uint256,uint256),(uint256,uint256,uint256,uint256),(uint256,uint256),bool)"
        );
        assertTrue(IAztecStaking.deposit.selector == bytes4(depositSig), "deposit signature bytes mismatch");
    }
}
