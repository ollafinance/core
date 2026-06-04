// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { GovActionBase } from "./GovActionBase.s.sol";

/// @title GovForceRebalanceReset
/// @notice Recovers a wedged rebalance state machine via OllaCore.forceRebalanceReset().
/// @dev forceRebalanceReset() is gated by Core GUARDIAN_ROLE. In the default deployment the
///      OllaGovernance timelock contract holds GUARDIAN_ROLE, so the call is scheduled+executed
///      as a timelock operation (reusing GovActionBase._runTimelockAction). If a separate guardian
///      wallet holds the role instead, this script logs the target/calldata for a direct call.
///
///      Salt: GovActionBase._salt() reads the SALT env var (default 0). To keep this action's
///      timelock operation id distinct from other ops, set SALT to _RECOMMENDED_SALT below
///      (logged at runtime). When SALT is unset, this script falls back to _RECOMMENDED_SALT.
contract GovForceRebalanceReset is GovActionBase {
    /// @notice Recommended unique salt for the forceRebalanceReset timelock operation.
    /// @dev Derived from a descriptive string so the operation id never collides with other Gov* ops.
    bytes32 internal constant _RECOMMENDED_SALT = keccak256("olla.ops.GovForceRebalanceReset.v1");

    function run() external {
        address governance = _governanceAddress();
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");

        // GovActionBase._salt() is not virtual, so it cannot be overridden. Seed the SALT env with
        // the descriptive default when the operator has not supplied one, so _runTimelockAction
        // computes the operation id against _RECOMMENDED_SALT.
        if (!vm.envExists("SALT")) {
            vm.setEnv("SALT", vm.toString(uint256(_RECOMMENDED_SALT)));
        }

        bytes32 guardianRole = OllaCore(core).GUARDIAN_ROLE();
        bool governanceIsGuardian = OllaCore(core).hasRole(guardianRole, governance);

        console2.log("governance", governance);
        console2.log("core", core);
        console2.log("guardianRole");
        console2.logBytes32(guardianRole);
        console2.log("governanceIsGuardian", governanceIsGuardian);
        console2.log("salt");
        console2.logBytes32(_salt());

        bytes memory data = abi.encodeCall(OllaCore.forceRebalanceReset, ());

        console2.log("target", core);
        console2.log("calldata");
        console2.logBytes(data);

        if (governanceIsGuardian) {
            console2.log("path", "timelock: OllaGovernance holds Core GUARDIAN_ROLE");
            _runTimelockAction(governance, core, data);
        } else {
            console2.log("path", "direct: a separate wallet holds Core GUARDIAN_ROLE");
            console2.log(
                "next.step",
                "Have the Core guardian wallet call OllaCore.forceRebalanceReset() directly (no timelock needed)."
            );
        }
    }
}
