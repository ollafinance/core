// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

/// @title IFinalizationCallback
/// @notice Hook fired by WithdrawalQueue once per request as it transitions to finalized.
/// @dev Implementer MUST gate this method to msg.sender == queue. The hook lets the vault
///      maintain its per-controller claimable shares aggregate inside the queue's loop,
///      so the two contracts share a single gas guard instead of stacking two unbounded loops.
interface IFinalizationCallback {
    /// @notice Notify the vault that a withdrawal request has been finalized.
    /// @param requestId The id of the finalized request.
    /// @param shares The shares burned for the request.
    function onWithdrawalFinalized(uint256 requestId, uint256 shares) external;
}
