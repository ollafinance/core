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
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role assigned to OllaCore for queue operations.
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the queue and roles.
    /// @param core_ OllaCore address.
    /// @param admin_ Default admin role address.
    function initialize(address core_, address admin_) external override initializer {
        if (core_ == address(0)) {
            revert WithdrawalQueue__ZeroAddress("core_");
        }
        if (admin_ == address(0)) {
            revert WithdrawalQueue__ZeroAddress("admin_");
        }

        __AccessControl_init();

        core = core_;
        nextRequestId = 1;
        nextPendingId = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CORE_ROLE, core_);
    }

    /// @notice Enqueues a new withdrawal request.
    /// @param recipient The request owner.
    /// @param shares The shares burned for the request.
    /// @param assetsExpected The assets expected when finalized.
    /// @param rate The exchange rate locked at request time.
    /// @return requestId The request id.
    function requestWithdrawal(address recipient, uint256 shares, uint256 assetsExpected, uint256 rate)
        external
        override
        onlyRole(CORE_ROLE)
        returns (uint256 requestId)
    {
        if (recipient == address(0)) {
            revert WithdrawalQueue__ZeroAddress("recipient");
        }
        if (shares == 0) {
            revert WithdrawalQueue__ZeroAmount("shares");
        }
        if (assetsExpected == 0) {
            revert WithdrawalQueue__ZeroAmount("assetsExpected");
        }

        requestId = nextRequestId;
        nextRequestId = requestId + 1;
        totalPendingAssets += assetsExpected;

        _requests[requestId] = WithdrawalRequest({
            recipient: recipient,
            finalized: false,
            claimed: false,
            shares: shares,
            assetsExpected: assetsExpected,
            rate: rate
        });

        emit WithdrawalRequested(requestId, recipient, shares, assetsExpected, rate);
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
        uint256 requestId;
        uint256 pendingAssets;
        (used, requestId, pendingAssets) = _previewFinalize(available);

        uint256 upperBound = requestId;
        uint256 currentId = nextPendingId;
        while (currentId < upperBound) {
            WithdrawalRequest storage request = _requests[currentId];
            if (!request.finalized) {
                request.finalized = true;
                emit WithdrawalFinalized(currentId, request.assetsExpected);
            }
            ++currentId;
        }

        totalPendingAssets = pendingAssets;
        nextPendingId = requestId;
        return used;
    }

    // slither-disable-end pess-multiple-storage-read

    // slither-disable-start pess-multiple-storage-read
    /// @notice Marks a finalized request as claimed.
    /// @param id The request id.
    /// @return assetsExpected The assets expected for the request.
    function claimWithdrawal(uint256 id) external override nonReentrant returns (uint256 assetsExpected) {
        WithdrawalRequest storage request = _requests[id];
        if (request.recipient == address(0)) {
            revert WithdrawalQueue__InvalidRequest(id);
        }
        if (!request.finalized) {
            revert WithdrawalQueue__NotFinalized(id);
        }
        if (request.claimed) {
            revert WithdrawalQueue__AlreadyClaimed(id);
        }

        request.claimed = true;
        assetsExpected = request.assetsExpected;
        emit WithdrawalClaimed(id, request.recipient, assetsExpected);
        return assetsExpected;
    }

    // slither-disable-end pess-multiple-storage-read

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the request struct for a given id.
    /// @param id The request id.
    /// @return request The request struct.
    function getRequest(uint256 id) external view override returns (WithdrawalRequest memory request) {
        request = _requests[id];
        if (request.recipient == address(0)) {
            revert WithdrawalQueue__InvalidRequest(id);
        }
        return request;
    }

    /// @notice Returns the next unfinalized request id.
    /// @return requestId The next unfinalized request id.
    function nextUnfinalized() external view override returns (uint256 requestId) {
        return nextPendingId;
    }

    /// @notice Previews assets used for withdrawal finalization.
    /// @param available The available assets to finalize.
    /// @return usedAssets The assets that would be used.
    function previewFinalizeWithdrawals(uint256 available) external view override returns (uint256 usedAssets) {
        (usedAssets,,) = _previewFinalize(available);
        return usedAssets;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // slither-disable-start pess-multiple-storage-read
    function _previewFinalize(uint256 available)
        internal
        view
        returns (uint256 usedAssets, uint256 nextPendingId_, uint256 pendingAssets)
    {
        nextPendingId_ = nextPendingId;
        uint256 upperBound = nextRequestId;
        pendingAssets = totalPendingAssets;

        while (nextPendingId_ < upperBound) {
            WithdrawalRequest storage request = _requests[nextPendingId_];
            uint256 assetsExpected = request.assetsExpected;

            if (!request.finalized) {
                if (available < assetsExpected) {
                    break;
                }

                available -= assetsExpected;
                usedAssets += assetsExpected;
                pendingAssets -= assetsExpected;
            }

            ++nextPendingId_;
        }

        return (usedAssets, nextPendingId_, pendingAssets);
    }

    // slither-disable-end pess-multiple-storage-read

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImplementation == address(0)) {
            revert WithdrawalQueue__ZeroAddress("newImplementation");
        }
    }
}
