// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SafeCast } from "@oz/utils/math/SafeCast.sol";
import { ReentrancyGuardTransient } from "@oz/utils/ReentrancyGuardTransient.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

/// @title WithdrawalQueue
/// @notice FIFO queue for async withdrawal requests.
/// @dev This queue uses strict FIFO ordering for finalization. Known limitation: a large request at the
///      head of the queue can block smaller requests behind it from being finalized, even if sufficient
///      liquidity exists for those smaller requests (head-of-line blocking). This is an intentional design
///      trade-off for simplicity, fairness (earlier requests are always served first), and gas efficiency
///      (no scanning past unfinalizable requests).
///      This contract does not hold or transfer tokens. Tokens sent directly to this address cannot be
///      recovered. All asset transfers are handled by OllaVault.
/// @author Olla Core contributors
contract WithdrawalQueue is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    IWithdrawalQueue
{
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
     //////////////////////////////////////////////////////////////*/

    /// @notice Maximum allowed gas threshold (30 million).
    uint256 private constant _MAX_GAS_THRESHOLD = 30_000_000;

    /// @notice Tolerance for rate comparison in slashing adjustment (1 wei).
    /// @dev Accounts for floor-rounding differences between the gross rate
    ///      (computed on aggregate state) and per-request rates (computed on per-request state).
    uint256 private constant _SLASHING_RATE_TOLERANCE = 1;

    /// @notice Scale factor for exchange rate calculations.
    uint256 private constant _RATE_SCALE = 1e18;

    /*//////////////////////////////////////////////////////////////
                                   STATE
     //////////////////////////////////////////////////////////////*/

    /// @notice OllaVault address.
    address public override vault;

    /// @notice Next request id to assign.
    uint64 public override nextRequestId;

    /// @notice Next pending request id to finalize.
    uint64 public override nextPendingId;

    /// @notice Gas threshold used to gate the finalization loop.
    uint32 private _gasThreshold;

    /// @notice Governance contract authorized to perform UUPS upgrades.
    address public governanceUpgradeAuthority;

    /// @notice Tracks all withdrawal requests.
    mapping(uint256 requestId => WithdrawalRequest request) private _requests;

    /// @notice Total assets outstanding across unfinalized requests.
    uint256 public override totalPendingAssets;

    /// @notice Total shares outstanding across unfinalized requests (burned but not yet finalized).
    uint256 public override totalPendingShares;

    /// @notice Storage gap for future upgrades.
    /// @dev When adding new state variables, append them above this gap and reduce its length
    ///      by the number of slots consumed. Target: 50 gap slots across all upgradeable contracts.
    // slither-disable-next-line unused-state
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error WithdrawalQueue__UnauthorizedGovernance(address caller);

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyVault() {
        if (msg.sender != vault) {
            revert IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault(msg.sender);
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
                             VAULT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IWithdrawalQueue
    function initialize(address vault_, address admin_, uint256 gasThreshold_) external override initializer {
        if (vault_ == address(0)) {
            revert WithdrawalQueue__ZeroAddress("vault_");
        }
        if (admin_ == address(0)) {
            revert WithdrawalQueue__ZeroAddress("admin_");
        }
        if (gasThreshold_ == 0) {
            revert WithdrawalQueue__InvalidParameter();
        }

        __AccessControl_init();

        vault = vault_;
        nextRequestId = 1;
        nextPendingId = 1;
        _gasThreshold = SafeCast.toUint32(gasThreshold_);
        governanceUpgradeAuthority = admin_;

        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @inheritdoc IWithdrawalQueue
    function setGasThreshold(uint256 threshold) external override onlyVault {
        if (threshold == 0) {
            revert WithdrawalQueue__InvalidParameter();
        }
        if (threshold > _MAX_GAS_THRESHOLD) {
            revert WithdrawalQueue__InvalidParameter();
        }
        uint256 oldThreshold = _gasThreshold;
        _gasThreshold = SafeCast.toUint32(threshold);
        emit GasThresholdUpdated(oldThreshold, threshold);
    }

    /// @inheritdoc IWithdrawalQueue
    function requestWithdrawal(address recipient, uint256 shares, uint256 assetsExpected, uint256 rate)
        external
        override
        onlyVault
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
        ++nextRequestId;
        totalPendingAssets += assetsExpected;
        totalPendingShares += shares;

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
    // FIFO loop reads request storage sequentially; caching is impractical for a variable-length loop.
    /// @inheritdoc IWithdrawalQueue
    /// @dev The loop processes requests in strict FIFO order and breaks (does not skip) when a request's
    ///      payout exceeds the remaining `available` liquidity. When `currentRate > 0`, each request's
    ///      payout is adjusted to `shares * min(currentRate, lockedRate) / 1e18`, so slashing losses
    ///      are shared proportionally and the queue cannot permanently block.
    function finalizeWithdrawals(uint256 available, uint256 currentRate, uint256 maxRequestId)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 used, uint256 finalizedCount, uint256 totalAdjusted)
    {
        uint256 requestTail = nextRequestId;
        uint256 upperBound = maxRequestId < requestTail ? maxRequestId : requestTail;
        return _finalizeWithdrawals(available, currentRate, upperBound);
    }

    // slither-disable-end pess-multiple-storage-read

    // slither-disable-start pess-multiple-storage-read
    // Reads and mutates a single request struct; multiple field accesses are required.
    /// @inheritdoc IWithdrawalQueue
    function claimWithdrawal(uint256 id) external override onlyVault nonReentrant returns (uint256 assetsExpected) {
        WithdrawalRequest storage request = _requests[id];
        if (request.recipient == address(0)) {
            revert WithdrawalQueue__InvalidRequest(id);
        }
        if (!request.finalized) {
            revert WithdrawalQueue__NotFinalized(id);
        }
        assetsExpected = request.assetsExpected;
        emit WithdrawalClaimed(id, request.recipient, assetsExpected);
        delete _requests[id];
        return assetsExpected;
    }

    // slither-disable-end pess-multiple-storage-read

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IWithdrawalQueue
    function getRequest(uint256 id) external view override returns (WithdrawalRequest memory request) {
        request = _requests[id];
        if (request.recipient == address(0)) {
            revert WithdrawalQueue__InvalidRequest(id);
        }
        return request;
    }

    /// @inheritdoc IWithdrawalQueue
    function nextUnfinalized() external view override returns (uint256 requestId) {
        return nextPendingId;
    }

    /// @inheritdoc IWithdrawalQueue
    function gasThreshold() external view override returns (uint32) {
        return _gasThreshold;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // slither-disable-start pess-multiple-storage-read
    // FIFO finalization intentionally reads sequential request storage entries.
    // Each iteration reads a different `_requests[currentId]`, so caching is not applicable.
    function _finalizeWithdrawals(uint256 available, uint256 currentRate, uint256 upperBound)
        internal
        returns (uint256 used, uint256 finalizedCount, uint256 totalAdjusted)
    {
        uint256 currentId = nextPendingId;
        uint256 pendingAssets = totalPendingAssets;
        uint256 pendingShares_ = totalPendingShares;

        while (currentId < upperBound) {
            if (gasleft() < _gasThreshold) {
                break;
            }

            WithdrawalRequest storage request = _requests[currentId];
            if (!request.finalized) {
                uint256 assetsExpected = request.assetsExpected;

                // Adjust payout when slashing has reduced the exchange rate below the locked rate.
                // The > 1 tolerance accounts for floor-rounding differences between the gross rate
                // (computed on aggregate state) and per-request rates (computed on per-request state).
                if (currentRate < request.rate && request.rate - currentRate > _SLASHING_RATE_TOLERANCE) {
                    uint256 payout = (request.shares * currentRate) / _RATE_SCALE;
                    if (payout < assetsExpected) {
                        // Check liquidity against the ADJUSTED payout before any storage write.
                        if (available < payout) {
                            break;
                        }
                        uint256 adjustment = assetsExpected - payout;
                        pendingAssets -= adjustment;
                        totalAdjusted += adjustment;
                        request.assetsExpected = payout;
                        assetsExpected = payout;
                        emit WithdrawalAdjusted(currentId, assetsExpected + adjustment, assetsExpected);
                    }
                }

                // Slashing reduced payout to zero; finalize without consuming liquidity
                // so the queue advances and the vault invariant
                // (finalizedAmount == 0) == (finalizedCount == 0) is preserved.
                if (assetsExpected == 0) {
                    pendingShares_ -= request.shares;
                    request.finalized = true;
                    emit WithdrawalFinalized(currentId, 0);
                    ++currentId;
                    continue;
                }

                // Breaks on first under-funded non-adjusted request; does not skip.
                if (available < assetsExpected) {
                    break;
                }

                available -= assetsExpected;
                used += assetsExpected;
                pendingAssets -= assetsExpected;
                pendingShares_ -= request.shares;
                request.finalized = true;
                ++finalizedCount;
                emit WithdrawalFinalized(currentId, assetsExpected);
            }

            ++currentId;
        }

        totalPendingAssets = pendingAssets;
        totalPendingShares = pendingShares_;
        nextPendingId = SafeCast.toUint64(currentId);
        return (used, finalizedCount, totalAdjusted);
    }

    // slither-disable-end pess-multiple-storage-read

    /// @notice Authorizes a UUPS upgrade; requires DEFAULT_ADMIN_ROLE and governance authority match.
    /// @param newImplementation The address of the new implementation contract.
    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != governanceUpgradeAuthority) {
            revert WithdrawalQueue__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert WithdrawalQueue__ZeroAddress("newImplementation");
        }
    }
}
