// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControl } from "@oz/access/AccessControl.sol";

import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { RolesLib } from "src/shared/RolesLib.sol";

/// @title SafetyModule
/// @notice Enforces deposit caps and circuit breaker checks.
/// @author Olla Core contributors
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

    // by convention, the other contracts has "core" as non-immutable
    // slither-disable-start immutable-states
    /// @notice The core address allowed to call checks.
    address public immutable CORE;
    // slither-disable-end immutable-states

    /// @notice Maximum total assets allowed.
    uint256 public depositCap;

    /// @notice Minimum withdrawal amount in shares.
    uint256 public withdrawalMinimum;

    /// @notice Whether the module is paused.
    bool public paused;

    /// @notice Minimum rate drop threshold in basis points.
    uint256 public minRateDropBps;

    /// @notice Maximum queued ratio in basis points.
    uint256 public maxQueueRatioBps;

    /// @notice Maximum delay allowed for accounting updates.
    uint256 public maxAccountingDelay;

    /// @notice Last accounting update timestamp.
    uint256 public lastAccountingTimestamp;

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCore() {
        if (msg.sender != CORE) {
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
    /// @param depositCap_ The initial deposit cap.
    /// @param minRateDropBps_ The minimum rate drop threshold in basis points.
    /// @param maxQueueRatioBps_ The maximum queue ratio threshold in basis points.
    /// @param maxAccountingDelay_ The maximum accounting delay in seconds.
    constructor(
        address admin,
        address guardian,
        address core_,
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
        withdrawalMinimum = 0;
        minRateDropBps = minRateDropBps_;
        maxQueueRatioBps = maxQueueRatioBps_;
        maxAccountingDelay = maxAccountingDelay_;
        lastAccountingTimestamp = block.timestamp;

        CORE = core_;

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
    function checkRateDrop(uint256 oldRate, uint256 nextRate) external override onlyCore {
        // solhint-disable-next-line gas-strict-inequalities
        if (nextRate >= oldRate) {
            return;
        }

        if (oldRate == 0) {
            _triggerBreaker(ISafetyModule.BreakerReason.RateDrop);
            return;
        }

        uint256 dropBps = (oldRate - nextRate) * BPS_DENOMINATOR / oldRate;
        // solhint-disable-next-line gas-strict-inequalities
        if (dropBps >= minRateDropBps) {
            _triggerBreaker(ISafetyModule.BreakerReason.RateDrop);
        }
    }

    /// @inheritdoc ISafetyModule
    function checkQueueRatio(uint256 queued, uint256 total) external override onlyCore {
        if (total == 0) {
            if (queued > 0) {
                _triggerBreaker(ISafetyModule.BreakerReason.QueueRatio);
            }
            return;
        }

        uint256 ratioBps = (queued * BPS_DENOMINATOR) / total;
        // solhint-disable-next-line gas-strict-inequalities
        if (ratioBps >= maxQueueRatioBps) {
            _triggerBreaker(ISafetyModule.BreakerReason.QueueRatio);
        }
    }

    /// @inheritdoc ISafetyModule
    function checkAccountingLiveness() external override onlyCore {
        // slither-disable-next-line timestamp
        // solhint-disable-next-line gas-strict-inequalities
        if (block.timestamp <= lastAccountingTimestamp) {
            return;
        }

        uint256 elapsed = block.timestamp - lastAccountingTimestamp;
        // slither-disable-next-line timestamp
        if (elapsed > maxAccountingDelay) {
            _triggerBreaker(ISafetyModule.BreakerReason.AccountingStale);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISafetyModule
    function setDepositCap(uint256 cap) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cap == 0) {
            revert SafetyModule__InvalidParameter();
        }
        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    /// @inheritdoc ISafetyModule
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
        minRateDropBps = minRateDropBps_;
        emit RateDropLimitUpdated(minRateDropBps_);
    }

    /// @inheritdoc ISafetyModule
    function setMaxQueueRatioBps(uint256 maxQueueRatioBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxQueueRatioBps_ < MIN_QUEUE_RATIO_BPS || maxQueueRatioBps_ > MAX_QUEUE_RATIO_BPS) {
            revert SafetyModule__InvalidParameter();
        }
        maxQueueRatioBps = maxQueueRatioBps_;
        emit QueueRatioLimitUpdated(maxQueueRatioBps_);
    }

    /// @inheritdoc ISafetyModule
    function setMaxAccountingDelay(uint256 maxAccountingDelay_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxAccountingDelay_ < MIN_ACCOUNTING_DELAY || maxAccountingDelay_ > MAX_ACCOUNTING_DELAY) {
            revert SafetyModule__InvalidParameter();
        }
        maxAccountingDelay = maxAccountingDelay_;
        emit AccountingDelayUpdated(maxAccountingDelay_);
    }

    /// @inheritdoc ISafetyModule
    function setLatestAccountingTimestamp(uint256 latestAccountingTimestamp_) external override onlyCore {
        lastAccountingTimestamp = latestAccountingTimestamp_;
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
    function checkDepositAllowed(uint256 deposit, uint256 total)
        external
        view
        override
        onlyCore
        returns (bool allowed)
    {
        if (deposit + total > depositCap) {
            return false;
        }
        return true;
    }

    /// @inheritdoc ISafetyModule
    function checkWithdrawalMinimum(uint256 shares) external view override onlyCore {
        if (shares < withdrawalMinimum) {
            revert SafetyModule__BelowWithdrawalMinimum(shares, withdrawalMinimum);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _triggerBreaker(ISafetyModule.BreakerReason reason) internal {
        emit CircuitBreakerTriggered(reason);
        if (!paused) {
            paused = true;
            emit Paused();
        }
    }
}
