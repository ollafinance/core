// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControl } from "@oz/access/AccessControl.sol";
import { SafeCast } from "@oz/utils/math/SafeCast.sol";

import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { RolesLib } from "src/shared/RolesLib.sol";

/// @title SafetyModule
/// @notice Enforces deposit caps and circuit breaker checks.
/// @author Olla Core contributors
/// @dev SafetyModule is intentionally **not** UUPS-upgradeable:
///  1. It is the protocol's safety/pause mechanism (circuit breaker). Making
///     it silently upgradeable would undermine its purpose as a trust anchor --
///     users must be able to reason about what can pause the protocol.
///  2. Its logic is simple (circuit breakers + pause) with minimal attack
///     surface, so the upgrade complexity/risk outweighs the benefit.
///  3. OllaCore exposes a `setSafetyModule()` setter (admin-only) that allows
///     replacing the module without upgrading the core proxy, providing an
///     escape hatch if a bug is discovered.
///  4. SafetyModule holds no user funds and has no cross-contract references
///     outside OllaCore, so swapping it carries no asset-safety or
///     consistency risk.
contract SafetyModule is AccessControl, ISafetyModule {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for guardian pause/unpause actions.
    bytes32 public constant GUARDIAN_ROLE = RolesLib.GUARDIAN_ROLE;

    /// @notice Basis points denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Minimum rate drop threshold: 1 bps.
    uint256 public constant MIN_RATE_DROP_BPS = 1;
    /// @notice Maximum rate drop threshold: 50%.
    uint256 public constant MAX_RATE_DROP_BPS = 5_000;
    /// @notice Minimum queue ratio threshold: 1%.
    uint256 public constant MIN_QUEUE_RATIO_BPS = 100;
    /// @notice Maximum queue ratio threshold: 90%.
    uint256 public constant MAX_QUEUE_RATIO_BPS = 9_000;
    /// @notice Minimum accounting delay: 1 hour.
    uint256 public constant MIN_ACCOUNTING_DELAY = 1 hours;
    /// @notice Maximum accounting delay: 7 days.
    uint256 public constant MAX_ACCOUNTING_DELAY = 7 days;
    /// @notice Maximum withdrawal minimum in shares.
    uint256 public constant MAX_WITHDRAWAL_MINIMUM = 1_000e18;

    /*//////////////////////////////////////////////////////////////
                                   STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The core address allowed to call checks.
    address public immutable CORE;

    /// @notice The vault address allowed to call user-facing checks.
    address public immutable VAULT;

    /// @notice Maximum total assets allowed.
    uint256 public depositCap;

    /// @notice Minimum withdrawal amount in shares.
    uint256 public withdrawalMinimum;

    /// @notice Whether the module is paused.
    bool public paused;

    /// @notice Minimum rate drop threshold in basis points.
    uint16 public minRateDropBps;

    /// @notice Maximum queued ratio in basis points.
    uint16 public maxQueueRatioBps;

    /// @notice Maximum delay allowed for accounting updates.
    uint32 public maxAccountingDelay;

    /// @notice Last accounting update timestamp.
    uint48 public lastAccountingTimestamp;

    /// @notice The breaker reason that most recently paused the module.
    ISafetyModule.BreakerReason public lastBreakerReason;

    /// @notice Latest high-water mark used for cumulative rate-drop checks.
    uint256 public rateHighWaterMark;

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCoreOrVault() {
        if (msg.sender != CORE && msg.sender != VAULT) {
            revert ISafetyModule.SafetyModule__UnauthorizedCore(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the SafetyModule with initial configuration.
    /// @param admin The default admin address.
    /// @param guardian The guardian address.
    /// @param core_ The core address allowed to call checks.
    /// @param vault_ The vault address allowed to call user-facing checks.
    /// @param depositCap_ The initial deposit cap.
    /// @param minRateDropBps_ The minimum rate drop threshold in basis points.
    /// @param maxQueueRatioBps_ The maximum queue ratio threshold in basis points.
    /// @param maxAccountingDelay_ The maximum accounting delay in seconds.
    constructor(
        address admin,
        address guardian,
        address core_,
        address vault_,
        uint256 depositCap_,
        uint256 minRateDropBps_,
        uint256 maxQueueRatioBps_,
        uint256 maxAccountingDelay_
    ) {
        if (admin == address(0)) {
            revert SafetyModule__ZeroAddress("admin");
        }
        if (guardian == address(0)) {
            revert SafetyModule__ZeroAddress("guardian");
        }
        if (core_ == address(0)) {
            revert SafetyModule__ZeroAddress("core");
        }
        if (vault_ == address(0)) {
            revert SafetyModule__ZeroAddress("vault");
        }
        if (depositCap_ == 0) {
            revert SafetyModule__InvalidParameter();
        }
        if (minRateDropBps_ < MIN_RATE_DROP_BPS || minRateDropBps_ > MAX_RATE_DROP_BPS) {
            revert SafetyModule__InvalidParameter();
        }
        if (maxQueueRatioBps_ < MIN_QUEUE_RATIO_BPS || maxQueueRatioBps_ > MAX_QUEUE_RATIO_BPS) {
            revert SafetyModule__InvalidParameter();
        }
        if (maxAccountingDelay_ < MIN_ACCOUNTING_DELAY || maxAccountingDelay_ > MAX_ACCOUNTING_DELAY) {
            revert SafetyModule__InvalidParameter();
        }

        depositCap = depositCap_;
        withdrawalMinimum = 100e18;
        minRateDropBps = SafeCast.toUint16(minRateDropBps_);
        maxQueueRatioBps = SafeCast.toUint16(maxQueueRatioBps_);
        maxAccountingDelay = SafeCast.toUint32(maxAccountingDelay_);
        lastAccountingTimestamp = SafeCast.toUint48(block.timestamp);

        CORE = core_;
        VAULT = vault_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);

        emit DepositCapUpdated(depositCap_);
        emit RateDropLimitUpdated(minRateDropBps_);
        emit QueueRatioLimitUpdated(maxQueueRatioBps_);
        emit AccountingDelayUpdated(maxAccountingDelay_);
        emit AccountingTimestampUpdated(lastAccountingTimestamp);
    }

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISafetyModule
    function checkRateDrop(uint256 oldRate, uint256 nextRate) external override onlyCoreOrVault {
        uint256 highWaterMark = rateHighWaterMark;
        if (highWaterMark == 0) {
            highWaterMark = oldRate > nextRate ? oldRate : nextRate;
            rateHighWaterMark = highWaterMark;
            emit RateHighWaterMarkUpdated(highWaterMark);
        }

        if (nextRate > highWaterMark) {
            rateHighWaterMark = nextRate;
            emit RateHighWaterMarkUpdated(nextRate);
            return;
        }

        if (nextRate < oldRate) {
            if (_checkRateDrop(oldRate, nextRate)) {
                return;
            }
        }

        if (nextRate <= oldRate && nextRate < highWaterMark) {
            _checkRateDrop(highWaterMark, nextRate);
        }
    }

    /// @inheritdoc ISafetyModule
    function checkQueueRatio(uint256 queued, uint256 total) external override onlyCoreOrVault {
        // `total` is totalAssets() which already subtracts pending withdrawals,
        // so the gross total is `queued + total`.
        uint256 gross = queued + total;
        if (gross == 0) {
            return;
        }

        uint256 ratioBps = (queued * BPS_DENOMINATOR) / gross;
        // solhint-disable-next-line gas-strict-inequalities
        if (ratioBps >= maxQueueRatioBps) {
            _triggerBreaker(ISafetyModule.BreakerReason.QueueRatio);
        }
    }

    /// @inheritdoc ISafetyModule
    function checkAccountingLiveness() external override onlyCoreOrVault {
        // Liveness check: compare current time against last accounting update.
        // slither-disable-next-line timestamp
        // solhint-disable-next-line gas-strict-inequalities
        if (block.timestamp <= lastAccountingTimestamp) {
            return;
        }

        uint256 elapsed = block.timestamp - lastAccountingTimestamp;
        // Staleness detection; triggers circuit breaker if accounting is overdue.
        // slither-disable-next-line timestamp
        if (elapsed > maxAccountingDelay) {
            _triggerBreaker(ISafetyModule.BreakerReason.AccountingStale);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISafetyModule
    /// @dev Lowering `depositCap` below current `totalAssets()` will cause `maxDeposit()` to
    ///      return 0, silently blocking all new deposits. This is a valid operational state for
    ///      controlled wind-down (deposits blocked, withdrawals open). The governance timelock
    ///      provides advance notice to users. Zero cap is rejected by the existing guard.
    function setDepositCap(uint256 cap) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cap == 0) {
            revert SafetyModule__InvalidParameter();
        }
        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    /// @inheritdoc ISafetyModule
    /// @dev This minimum prevents zero-payout rounding during withdrawal finalization under slashing.
    ///      With withdrawalMinimum = 100e18, zero payout requires >99.999999% exchange rate collapse,
    ///      far beyond realistic slashing scenarios. Must be set to a non-zero value before launch.
    ///      Increasing `withdrawalMinimum` can retroactively prevent users with fewer shares
    ///      from withdrawing. This is mitigated by the governance timelock (advance notice) and
    ///      the expectation that minimum is set conservatively at launch. Bounded by MAX_WITHDRAWAL_MINIMUM.
    function setWithdrawalMinimum(uint256 minimumShares) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minimumShares > MAX_WITHDRAWAL_MINIMUM) {
            revert SafetyModule__InvalidParameter();
        }
        withdrawalMinimum = minimumShares;
        emit WithdrawalMinimumUpdated(minimumShares);
    }

    /// @inheritdoc ISafetyModule
    function setMinRateDropBps(uint256 minRateDropBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minRateDropBps_ < MIN_RATE_DROP_BPS || minRateDropBps_ > MAX_RATE_DROP_BPS) {
            revert SafetyModule__InvalidParameter();
        }
        minRateDropBps = SafeCast.toUint16(minRateDropBps_);
        emit RateDropLimitUpdated(minRateDropBps_);
    }

    /// @inheritdoc ISafetyModule
    function setRateHighWaterMark(uint256 rateHighWaterMark_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (rateHighWaterMark_ == 0) revert SafetyModule__InvalidParameter();
        rateHighWaterMark = rateHighWaterMark_;
        emit RateHighWaterMarkUpdated(rateHighWaterMark_);
    }

    /// @inheritdoc ISafetyModule
    function setMaxQueueRatioBps(uint256 maxQueueRatioBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxQueueRatioBps_ < MIN_QUEUE_RATIO_BPS || maxQueueRatioBps_ > MAX_QUEUE_RATIO_BPS) {
            revert SafetyModule__InvalidParameter();
        }
        maxQueueRatioBps = SafeCast.toUint16(maxQueueRatioBps_);
        emit QueueRatioLimitUpdated(maxQueueRatioBps_);
    }

    /// @inheritdoc ISafetyModule
    function setMaxAccountingDelay(uint256 maxAccountingDelay_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxAccountingDelay_ < MIN_ACCOUNTING_DELAY || maxAccountingDelay_ > MAX_ACCOUNTING_DELAY) {
            revert SafetyModule__InvalidParameter();
        }
        maxAccountingDelay = SafeCast.toUint32(maxAccountingDelay_);
        emit AccountingDelayUpdated(maxAccountingDelay_);
    }

    /// @inheritdoc ISafetyModule
    function setLatestAccountingTimestamp(uint256 latestAccountingTimestamp_) external override onlyCoreOrVault {
        // Reject future timestamps; block.timestamp comparison is intentional.
        // slither-disable-next-line timestamp
        if (latestAccountingTimestamp_ > block.timestamp) revert SafetyModule__InvalidParameter();
        lastAccountingTimestamp = SafeCast.toUint48(latestAccountingTimestamp_);
        emit AccountingTimestampUpdated(latestAccountingTimestamp_);
    }

    /// @inheritdoc ISafetyModule
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        if (paused) {
            return;
        }
        paused = true;
        emit Paused();
    }

    /// @inheritdoc ISafetyModule
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        if (!paused) {
            return;
        }
        paused = false;
        emit Unpaused();
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISafetyModule
    function isPaused() external view override returns (bool pausedState) {
        return paused;
    }

    /// @inheritdoc ISafetyModule
    function isDepositPaused() external view override returns (bool pausedState) {
        return paused && lastBreakerReason != ISafetyModule.BreakerReason.QueueRatio;
    }

    /// @inheritdoc ISafetyModule
    function checkDepositAllowed(uint256 deposit, uint256 total)
        external
        view
        override
        onlyCoreOrVault
        returns (bool allowed)
    {
        if (deposit > depositCap || total > depositCap - deposit) {
            return false;
        }
        return true;
    }

    /// @inheritdoc ISafetyModule
    function checkWithdrawalMinimum(uint256 shares) external view override onlyCoreOrVault {
        if (shares < withdrawalMinimum) {
            revert SafetyModule__BelowWithdrawalMinimum(shares, withdrawalMinimum);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _checkRateDrop(uint256 referenceRate, uint256 nextRate) internal returns (bool triggered) {
        uint256 dropBps = (referenceRate - nextRate) * BPS_DENOMINATOR / referenceRate;
        // solhint-disable-next-line gas-strict-inequalities
        if (dropBps >= minRateDropBps) {
            bool pausedBefore = paused;
            ISafetyModule.BreakerReason reasonBefore = lastBreakerReason;
            _triggerBreaker(ISafetyModule.BreakerReason.RateDrop);
            if (!pausedBefore || reasonBefore != ISafetyModule.BreakerReason.QueueRatio) {
                rateHighWaterMark = nextRate;
                emit RateHighWaterMarkUpdated(nextRate);
            }
            return true;
        }
        return false;
    }

    /// @notice Pauses the module and emits the circuit breaker event if not already paused.
    /// @param reason The breaker reason to emit.
    function _triggerBreaker(ISafetyModule.BreakerReason reason) internal {
        lastBreakerReason = reason;
        if (!paused) {
            paused = true;
            emit CircuitBreakerTriggered(reason);
            emit Paused();
        }
    }
}
