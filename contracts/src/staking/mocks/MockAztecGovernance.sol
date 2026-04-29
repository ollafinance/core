// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IAztecGovernance } from "src/staking/interfaces/IAztecGovernance.sol";
import { Timestamp } from "src/staking/libraries/AztecTypes.sol";

/// @title MockAztecGovernance
/// @notice Mock Aztec Governance withdrawal reader for staking tests.
contract MockAztecGovernance is IAztecGovernance {
    mapping(uint256 withdrawalId => Withdrawal withdrawal) private _withdrawals;

    /// @notice Sets a withdrawal record.
    /// @param withdrawalId The withdrawal id.
    /// @param amount The withdrawal amount.
    /// @param unlocksAt The timestamp when the withdrawal unlocks.
    /// @param recipient The withdrawal recipient.
    /// @param claimed Whether the withdrawal has already been claimed.
    function setWithdrawal(uint256 withdrawalId, uint256 amount, uint256 unlocksAt, address recipient, bool claimed)
        external
    {
        _withdrawals[withdrawalId] = Withdrawal({
            amount: amount, unlocksAt: Timestamp.wrap(unlocksAt), recipient: recipient, claimed: claimed
        });
    }

    /// @inheritdoc IAztecGovernance
    function getWithdrawal(uint256 withdrawalId) external view override returns (Withdrawal memory withdrawal) {
        withdrawal = _withdrawals[withdrawalId];
        if (withdrawal.recipient == address(0)) {
            withdrawal.claimed = true;
        }
        return withdrawal;
    }
}
