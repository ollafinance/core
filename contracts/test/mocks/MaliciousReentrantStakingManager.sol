// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

/// @title MaliciousReentrantStakingManager
/// @notice Test mock that attempts to reenter OllaCore during getUnstakedFunds.
contract MaliciousReentrantStakingManager is MockAccountingStakingManager {
    /*//////////////////////////////////////////////////////////////
                                  ENUMS
    //////////////////////////////////////////////////////////////*/

    enum ReentryAction {
        None,
        Rebalance
    }

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    IOllaCore public coreRef;
    ReentryAction public action;

    /*//////////////////////////////////////////////////////////////
                               TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    function setReentry(IOllaCore core_, ReentryAction action_) external {
        coreRef = core_;
        action = action_;
    }

    /*//////////////////////////////////////////////////////////////
                               CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getUnstakedFunds() public override returns (uint256 received) {
        _attemptReentry();
        return super.getUnstakedFunds();
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _attemptReentry() internal {
        IOllaCore coreTarget = coreRef;
        if (address(coreTarget) == address(0)) {
            return;
        }

        if (action == ReentryAction.Rebalance) {
            coreTarget.rebalance();
            return;
        }
    }
}
