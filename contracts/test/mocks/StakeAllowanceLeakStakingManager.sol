// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";

import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

/// @title StakeAllowanceLeakStakingManager
/// @notice Test mock with configurable failure modes for `stake()`. Used to verify the
///         staking flow's allowance hygiene under partial fills and reverts:
///           1. `stake()` reverts entirely (exercises the caller's catch path).
///           2. `stake()` accepts only part of the requested amount, pulling only that
///              part of the approved allowance via `transferFrom`.
/// @dev    Inherits from MockAccountingStakingManager so the rest of the OllaCore rebalance
///         pipeline keeps working unchanged.
contract StakeAllowanceLeakStakingManager is MockAccountingStakingManager {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    bool public stakeShouldRevert;
    bool public stakePartialMode;
    uint256 public stakePartialAmount;

    /*//////////////////////////////////////////////////////////////
                               TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Configures `stake()` to revert with a generic error so callers exercise
    ///         their failure branch.
    function setStakeShouldRevert(bool shouldRevert_) external {
        stakeShouldRevert = shouldRevert_;
    }

    /// @notice Configures `stake()` to behave like a real partial-stake by pulling
    ///         only `partialAmount` tokens via transferFrom (consuming only that
    ///         portion of the approved allowance) and reporting it as the actual
    ///         staked amount.
    function setStakePartial(uint256 partialAmount_) external {
        stakePartialMode = true;
        stakePartialAmount = partialAmount_;
    }

    function clearStakeMode() external {
        stakeShouldRevert = false;
        stakePartialMode = false;
        stakePartialAmount = 0;
    }

    /*//////////////////////////////////////////////////////////////
                               STAKE OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc MockAccountingStakingManager
    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        if (stakeShouldRevert) {
            revert StakeRejected();
        }

        if (stakePartialMode) {
            uint256 actualAmount = stakePartialAmount;
            if (actualAmount > amount) {
                actualAmount = amount;
            }
            // Mirror the real StakingManager: `safeTransferFrom(caller, ..., amount)` for the
            // portion actually consumed, so the remaining approved allowance reflects only
            // what was not pulled.
            if (actualAmount != 0 && address(rewardsToken) != address(0)) {
                IERC20(address(rewardsToken)).safeTransferFrom(msg.sender, address(this), actualAmount);
            }
            return actualAmount;
        }

        // Default behaviour: fall back to MockAccountingStakingManager's defaults
        // by mimicking its full-stake path (consume the full approved amount).
        if (amount != 0 && address(rewardsToken) != address(0)) {
            IERC20(address(rewardsToken)).safeTransferFrom(msg.sender, address(this), amount);
        }
        return amount;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error StakeRejected();
}
