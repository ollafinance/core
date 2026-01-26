// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Address } from "@oz/utils/Address.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { IMaliciousWithdrawalQueue } from "src/core/mocks/IMaliciousWithdrawalQueue.sol";

/// @title MaliciousWithdrawalQueue
/// @notice Test-only withdrawal queue that attempts reentrancy on selected entrypoints.
/// @author Olla Core contributors
contract MaliciousWithdrawalQueue is IMaliciousWithdrawalQueue, IWithdrawalQueue {
    using Address for address;

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

    address private _reentryTarget;
    bytes private _reentryCalldata;
    bool private _reenterOnRequest;
    bool private _reenterOnClaim;
    bool private _reenterOnFinalize;

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

    /// @notice Configure the call to perform during a reentrancy attempt.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    function setReentry(address target, bytes calldata data) external override {
        _reentryTarget = target;
        _reentryCalldata = data;
    }

    /// @notice Enable/disable reentrancy during requestWithdrawal.
    /// @param enabled Whether to enable reentrancy.
    function setReenterOnRequest(bool enabled) external override {
        _reenterOnRequest = enabled;
    }

    /// @notice Enable/disable reentrancy during claimWithdrawal.
    /// @param enabled Whether to enable reentrancy.
    function setReenterOnClaim(bool enabled) external override {
        _reenterOnClaim = enabled;
    }

    /// @notice Enable/disable reentrancy during finalizeWithdrawals.
    /// @param enabled Whether to enable reentrancy.
    function setReenterOnFinalize(bool enabled) external override {
        _reenterOnFinalize = enabled;
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
        if (_reenterOnRequest) {
            _reenterOnRequest = false;
            _reentryTarget.functionCall(_reentryCalldata);
        }

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
    function finalizeWithdrawals(uint256 available) external override returns (uint256 used) {
        if (_reenterOnFinalize) {
            _reenterOnFinalize = false;
            _reentryTarget.functionCall(_reentryCalldata);
        }

        lastAvailable = available;
        return available;
    }

    /// @notice Marks a request as claimed.
    /// @param id The request id.
    /// @return assetsExpected The assets expected for the request.
    function claimWithdrawal(uint256 id) external override returns (uint256 assetsExpected) {
        if (_reenterOnClaim) {
            _reenterOnClaim = false;
            _reentryTarget.functionCall(_reentryCalldata);
        }

        WithdrawalRequest storage request = _requests[id];
        request.claimed = true;
        assetsExpected = request.assetsExpected;
        return assetsExpected;
    }

    /*//////////////////////////////////////////////////////////////
                             EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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

    /// @notice Previews assets used for withdrawal finalization.
    /// @param available The available assets to finalize.
    /// @return used The assets that would be used.
    function previewFinalizeWithdrawals(uint256 available) external pure override returns (uint256 used) {
        return available;
    }
}
