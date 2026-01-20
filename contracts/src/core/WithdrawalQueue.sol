// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { IWithdrawalQueue } from "src/interfaces/IWithdrawalQueue.sol";

/// @title WithdrawalQueue
/// @notice FIFO queue for async withdrawal requests.
/// @author Olla Core contributors
contract WithdrawalQueue is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IWithdrawalQueue
{
    /// @notice Role assigned to OllaCore for queue operations.
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    /// @notice OllaCore address.
    address public override core;

    /// @notice Next request id to assign.
    uint256 public override nextRequestId;

    /// @notice Next pending request id to finalize.
    uint256 public override nextPendingId;

    /// @notice Tracks all withdrawal requests.
    mapping(uint256 requestId => WithdrawalRequest request) private _requests;

    /// @notice Total assets outstanding across unfinalized requests.
    uint256 public override totalPendingAssets;

    /// @notice Storage gap for upgradability.
    // slither-disable-next-line unused-state
    uint256[45] private __gap;

    /// @notice Thrown when a zero address is provided.
    error WithdrawalQueueZeroAddress();

    /// @notice Thrown when a request amount is invalid.
    error WithdrawalQueueInvalidAmount();

    /// @notice Thrown when a request is not finalized.
    error WithdrawalQueueNotFinalized(uint256 id);

    /// @notice Thrown when a request is already claimed.
    error WithdrawalQueueAlreadyClaimed(uint256 id);

    /// @notice Thrown when a request id is invalid.
    error WithdrawalQueueInvalidRequest(uint256 id);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the queue and roles.
    /// @param core_ OllaCore address.
    /// @param admin_ Default admin role address.
    function initialize(address core_, address admin_) external override initializer {
        if (core_ == address(0) || admin_ == address(0)) {
            revert WithdrawalQueueZeroAddress();
        }

        __AccessControl_init();

        core = core_;
        nextRequestId = 1;
        nextPendingId = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CORE_ROLE, core_);
    }

    /// @notice Enqueues a new withdrawal request.
    /// @param user The request owner.
    /// @param shares The shares burned for the request.
    /// @param assetsExpected The assets expected when finalized.
    /// @param rate The exchange rate locked at request time.
    /// @return requestId The request id.
    function requestWithdrawal(address user, uint256 shares, uint256 assetsExpected, uint256 rate)
        external
        override
        onlyRole(CORE_ROLE)
        returns (uint256 requestId)
    {
        if (user == address(0)) {
            revert WithdrawalQueueZeroAddress();
        }
        if (shares == 0 || assetsExpected == 0) {
            revert WithdrawalQueueInvalidAmount();
        }

        requestId = nextRequestId;
        nextRequestId = requestId + 1;
        totalPendingAssets += assetsExpected;

        _requests[requestId] = WithdrawalRequest({
            user: user, finalized: false, claimed: false, shares: shares, assetsExpected: assetsExpected, rate: rate
        });

        emit WithdrawalRequested(requestId, user, shares, assetsExpected, rate);
        return requestId;
    }

    // slither-disable-start pess-multiple-storage-read
    /// @notice Finalizes withdrawals using available liquidity.
    /// @param available The available assets to finalize.
    /// @return used The assets used for finalization.
    function finalizeWithdrawals(uint256 available)
        external
        override
        onlyRole(CORE_ROLE)
        nonReentrant
        returns (uint256 used)
    {
        uint256 requestId = nextPendingId;
        uint256 upperBound = nextRequestId;
        uint256 usedAssets = 0;
        uint256 pendingAssets = totalPendingAssets;

        while (requestId < upperBound) {
            WithdrawalRequest storage request = _requests[requestId];

            uint256 assetsExpected = request.assetsExpected;

            if (!request.finalized) {
                if (available < assetsExpected) {
                    break;
                }

                request.finalized = true;
                pendingAssets -= assetsExpected;
                available -= assetsExpected;
                usedAssets += assetsExpected;

                emit WithdrawalFinalized(requestId, assetsExpected);
            }

            ++requestId;
        }

        totalPendingAssets = pendingAssets;
        nextPendingId = requestId;
        return usedAssets;
    }

    // slither-disable-end pess-multiple-storage-read

    // slither-disable-start pess-multiple-storage-read
    /// @notice Marks a finalized request as claimed.
    /// @param id The request id.
    /// @return assetsExpected The assets expected for the request.
    function claimWithdrawal(uint256 id) external override nonReentrant returns (uint256 assetsExpected) {
        WithdrawalRequest storage request = _requests[id];
        if (request.user == address(0)) {
            revert WithdrawalQueueInvalidRequest(id);
        }
        if (!request.finalized) {
            revert WithdrawalQueueNotFinalized(id);
        }
        if (request.claimed) {
            revert WithdrawalQueueAlreadyClaimed(id);
        }

        request.claimed = true;
        assetsExpected = request.assetsExpected;
        emit WithdrawalClaimed(id, request.user, assetsExpected);
        return assetsExpected;
    }

    // slither-disable-end pess-multiple-storage-read

    /// @notice Returns the request struct for a given id.
    /// @param id The request id.
    /// @return request The request struct.
    function getRequest(uint256 id) external view override returns (WithdrawalRequest memory request) {
        request = _requests[id];
        if (request.user == address(0)) {
            revert WithdrawalQueueInvalidRequest(id);
        }
        return request;
    }

    /// @notice Returns the next unfinalized request id.
    /// @return requestId The next unfinalized request id.
    function nextUnfinalized() external view override returns (uint256 requestId) {
        return nextPendingId;
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImplementation == address(0)) {
            revert WithdrawalQueueZeroAddress();
        }
    }
}
