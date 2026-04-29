// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { Timestamp } from "src/staking/libraries/AztecTypes.sol";

/// @title IAztecGovernance
/// @notice Minimal interface for Aztec Governance withdrawal reads.
/// @dev Mirrors the withdrawal getter used by GSE.finalizeWithdraw.
interface IAztecGovernance {
    struct Withdrawal {
        uint256 amount;
        Timestamp unlocksAt;
        address recipient;
        bool claimed;
    }

    /// @notice Returns a pending governance withdrawal by id.
    /// @param withdrawalId The governance withdrawal id.
    /// @return withdrawal The withdrawal record.
    function getWithdrawal(uint256 withdrawalId) external view returns (Withdrawal memory withdrawal);
}
