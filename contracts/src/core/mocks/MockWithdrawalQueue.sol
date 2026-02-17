// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";

/// @title MockWithdrawalQueue
/// @notice Minimal withdrawal queue mock for unit tests.
/// @author Olla Core contributors
contract MockWithdrawalQueue is IWithdrawalQueue {
    /// @notice Last finalize available value observed.
    uint256 public lastAvailable;

    /// @notice Mocked core address.
    address public override core;

    /// @notice Next request id to assign.
    uint256 public override nextRequestId = 1;

    /// @notice Next pending request id to finalize.
    uint256 public override nextPendingId = 1;

    /// @notice Total pending assets (not enforced in mock).
    uint256 public override totalPendingAssets;

    /// @notice Last request snapshot recorded.
    WithdrawalRequest public lastRequest;

    /// @notice Stored requests by id.
    mapping(uint256 requestId => WithdrawalRequest request) internal _requests;

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the mock with a core address.
    /// @param core_ OllaCore address.
    /// @param admin_ Unused admin address.
    function initialize(address core_, address admin_) external override {
        core = core_;
        admin_;
    }

    /// @notice Records a withdrawal request.
    /// @param recipient The request owner.
    /// @param shares The shares burned for the request.
    /// @param assetsExpected The assets expected when finalized.
    /// @param rate The exchange rate locked at request time.
    /// @return requestId The request id.
    function requestWithdrawal(address recipient, uint256 shares, uint256 assetsExpected, uint256 rate)
        external
        override
        returns (uint256 requestId)
    {
        requestId = nextRequestId;
        ++nextRequestId;
        WithdrawalRequest memory request = WithdrawalRequest({
            recipient: recipient,
            finalized: false,
            claimed: false,
            shares: shares,
            assetsExpected: assetsExpected,
            rate: rate
        });
        lastRequest = request;
        _requests[requestId] = request;
        totalPendingAssets += assetsExpected;
        return requestId;
    }

    /// @notice Records finalize calls and returns available amount.
    /// @param available The available assets to finalize.
    /// @return used The assets used for finalization.
    /// @return finalizedCount The number of requests finalized.
    function finalizeWithdrawals(uint256 available) external override returns (uint256 used, uint256 finalizedCount) {
        lastAvailable = available;
        // Finalize up to available amount, capped by totalPendingAssets
        used = available > totalPendingAssets ? totalPendingAssets : available;
        if (used > 0) {
            totalPendingAssets -= used;
            finalizedCount = 1; // Simplified: assume 1 request finalized if any used
        }
        return (used, finalizedCount);
    }

    /// @notice Marks a request as claimed.
    /// @param id The request id.
    /// @return assetsExpected The assets expected for the request.
    function claimWithdrawal(uint256 id) external override returns (uint256 assetsExpected) {
        WithdrawalRequest storage request = _requests[id];
        request.claimed = true;
        assetsExpected = request.assetsExpected;
        return assetsExpected;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // solhint-disable comprehensive-interface
    /// @notice Sets the finalized flag on a stored request (test helper).
    /// @param id The request id.
    /// @param finalized Whether the request is finalized.
    function setRequestFinalized(uint256 id, bool finalized) external {
        _requests[id].finalized = finalized;
    }

    // solhint-enable comprehensive-interface

    /// @notice Returns the request struct for a given id.
    /// @param id The request id.
    /// @return request The request struct.
    function getRequest(uint256 id) external view override returns (WithdrawalRequest memory request) {
        return _requests[id];
    }

    /// @notice Returns the next unfinalized request id.
    /// @return requestId The next pending request id.
    function nextUnfinalized() external view override returns (uint256 requestId) {
        return nextPendingId;
    }
}
