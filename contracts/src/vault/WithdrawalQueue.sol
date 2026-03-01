// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { OwnableUpgradeable } from "@oz-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

/// @title WithdrawalQueue
/// @notice FIFO queue for async withdrawal requests.
/// @dev This queue uses strict FIFO ordering for finalization. Known limitation: a large request at the
///      head of the queue can block smaller requests behind it from being finalized, even if sufficient
///      liquidity exists for those smaller requests (head-of-line blocking). This is an intentional design
///      trade-off for simplicity, fairness (earlier requests are always served first), and gas efficiency
///      (no scanning past unfinalizable requests).
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

    /// @notice Maximum allowed gas threshold (30 million).
    uint256 private constant _MAX_GAS_THRESHOLD = 30_000_000;

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

    /// @notice Gas threshold used to gate the finalization loop.
    uint256 private _gasThreshold;

    /// @notice Storage gap for upgradability.
    /// @dev State variables occupy 6 slots. When adding new state variables, append them above
    ///      this gap and reduce its length by the number of slots consumed.
    // slither-disable-next-line unused-state
    uint256[44] private __gap;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error WithdrawalQueue__UnauthorizedGovernance(address caller);

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCore() {
        if (msg.sender != core) {
            revert IWithdrawalQueue.WithdrawalQueue__UnauthorizedCore(msg.sender);
        }
        _;
    }

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
    /// @param gasThreshold_ Initial gas threshold for the finalization loop.
    function initialize(address core_, address admin_, uint256 gasThreshold_) external override initializer {
        if (core_ == address(0)) {
            revert WithdrawalQueue__ZeroAddress("core_");
        }
        if (admin_ == address(0)) {
            revert WithdrawalQueue__ZeroAddress("admin_");
        }
        if (gasThreshold_ == 0) {
            revert WithdrawalQueue__InvalidParameter();
        }

        __AccessControl_init();

        core = core_;
        nextRequestId = 1;
        nextPendingId = 1;
        _gasThreshold = gasThreshold_;

        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Sets the gas threshold used for the finalization loop.
    /// @param threshold The new gas threshold.
    function setGasThreshold(uint256 threshold) external override onlyCore {
        if (threshold == 0) {
            revert WithdrawalQueue__InvalidParameter();
        }
        if (threshold > _MAX_GAS_THRESHOLD) {
            revert WithdrawalQueue__InvalidParameter();
        }
        uint256 oldThreshold = _gasThreshold;
        _gasThreshold = threshold;
        emit GasThresholdUpdated(oldThreshold, threshold);
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
        onlyCore
        nonReentrant
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
    /// @dev The loop processes requests in strict FIFO order and breaks (does not skip) when a request's
    ///      `assetsExpected` exceeds the remaining `available` liquidity. This means a single large
    ///      unfinalizable request at the head blocks all subsequent requests, even smaller ones with
    ///      sufficient liquidity. This is a known limitation.
    /// @param available The available assets to finalize.
    /// @return used The assets used for finalization.
    /// @return finalizedCount The number of requests finalized.
    function finalizeWithdrawals(uint256 available)
        external
        override
        onlyCore
        nonReentrant
        returns (uint256 used, uint256 finalizedCount)
    {
        uint256 currentId = nextPendingId;
        uint256 upperBound = nextRequestId;
        uint256 pendingAssets = totalPendingAssets;

        while (currentId < upperBound) {
            if (gasleft() < _gasThreshold) {
                break;
            }

            WithdrawalRequest storage request = _requests[currentId];
            if (!request.finalized) {
                uint256 assetsExpected = request.assetsExpected;
                // Breaks on first under-funded request; does not skip.
                if (available < assetsExpected) {
                    break;
                }

                available -= assetsExpected;
                used += assetsExpected;
                pendingAssets -= assetsExpected;
                request.finalized = true;
                ++finalizedCount;
                emit WithdrawalFinalized(currentId, assetsExpected);
            }

            ++currentId;
        }

        totalPendingAssets = pendingAssets;
        nextPendingId = currentId;
        return (used, finalizedCount);
    }

    // slither-disable-end pess-multiple-storage-read

    // slither-disable-start pess-multiple-storage-read
    /// @notice Marks a finalized request as claimed.
    /// @param id The request id.
    /// @return assetsExpected The assets expected for the request.
    function claimWithdrawal(uint256 id) external override onlyCore nonReentrant returns (uint256 assetsExpected) {
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

    /// @notice Returns the gas threshold for the finalization loop.
    /// @return The gas threshold.
    function gasThreshold() external view override returns (uint256) {
        return _gasThreshold;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != OwnableUpgradeable(core).owner()) {
            revert WithdrawalQueue__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert WithdrawalQueue__ZeroAddress("newImplementation");
        }
    }
}
