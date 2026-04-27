// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { Address } from "@oz/utils/Address.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { IMaliciousWithdrawalQueue } from "src/vault/mocks/IMaliciousWithdrawalQueue.sol";

/// @title MaliciousWithdrawalQueue
/// @notice Test-only withdrawal queue that attempts reentrancy on selected entrypoints.
/// @author Olla Core contributors
contract MaliciousWithdrawalQueue is IMaliciousWithdrawalQueue, IWithdrawalQueue {
    using Address for address;

    /// @notice Last finalize available value observed.
    uint256 public lastAvailable;

    /// @notice Mocked vault address.
    address public override vault;

    /// @notice Next request id to assign.
    uint64 public override nextRequestId = 1;

    /// @notice Next pending request id to finalize.
    uint64 public override nextPendingId = 1;

    /// @notice Total pending assets (not enforced in mock).
    uint256 public override totalPendingAssets;

    /// @notice Total pending shares (not enforced in mock).
    uint256 public override totalPendingShares;

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
                              VAULT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas threshold value.
    uint32 private _gasThresholdValue;

    /// @notice Initializes the mock with a vault address.
    /// @param vault_ OllaVault address.
    /// @param admin_ Unused admin address.
    /// @param gasThreshold_ Initial gas threshold.
    function initialize(address vault_, address admin_, uint256 gasThreshold_) external override {
        vault = vault_;
        _gasThresholdValue = uint32(gasThreshold_);
        admin_;
    }

    /// @notice Sets the gas threshold.
    /// @param threshold The new gas threshold.
    function setGasThreshold(uint256 threshold) external override {
        _gasThresholdValue = uint32(threshold);
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
        totalPendingShares += shares;
        return requestId;
    }

    /// @notice Records finalize calls and returns available amount.
    /// @param available The available assets to finalize.
    /// @param currentRate The current exchange rate (ignored in mock).
    /// @return used The assets used for finalization.
    /// @return finalizedCount The number of requests finalized.
    /// @return totalAdjusted Always 0 in mock.
    /// @inheritdoc IWithdrawalQueue
    function finalizeWithdrawals(uint256 available, uint256 currentRate, uint256 maxRequestId)
        external
        override
        returns (uint256 used, uint256 finalizedCount, uint256 totalAdjusted)
    {
        if (_reenterOnFinalize) {
            _reenterOnFinalize = false;
            _reentryTarget.functionCall(_reentryCalldata);
        }

        uint256 requestTail = nextRequestId;
        uint256 upperBound = maxRequestId < requestTail ? maxRequestId : requestTail;
        return _finalizeWithdrawals(available, currentRate, upperBound);
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

    /// @notice Returns the gas threshold.
    /// @return The gas threshold.
    function gasThreshold() external view override returns (uint32) {
        return _gasThresholdValue;
    }

    function _finalizeWithdrawals(uint256 available, uint256 currentRate, uint256 upperBound)
        internal
        returns (uint256 used, uint256 finalizedCount, uint256 totalAdjusted)
    {
        lastAvailable = available;
        currentRate; // silence unused warning
        if (available == 0 || totalPendingAssets == 0) {
            return (0, 0, 0);
        }

        used = 0;
        finalizedCount = 0;
        uint256 id = nextPendingId;
        for (; id < upperBound; ++id) {
            WithdrawalRequest storage request = _requests[id];
            if (request.finalized || request.assetsExpected == 0) continue;
            if (used + request.assetsExpected > available) break;
            request.finalized = true;
            used += request.assetsExpected;
            ++finalizedCount;
        }
        nextPendingId = uint64(id);
        if (totalPendingAssets >= used) {
            totalPendingAssets -= used;
        }
        return (used, finalizedCount, 0);
    }
}
