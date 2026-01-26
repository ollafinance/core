// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControl } from "@oz/access/AccessControl.sol";

import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

/// @title SafetyModule
/// @notice Enforces deposit caps and circuit breaker checks.
/// @author Olla Core contributors
contract SafetyModule is AccessControl, ISafetyModule {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for guardian pause/unpause actions.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Role for core module checks.
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    /// @notice Circuit breaker reason: rate drop.
    bytes32 public constant RATE_DROP = keccak256("RATE_DROP");

    /// @notice Circuit breaker reason: queue ratio exceeded.
    bytes32 public constant QUEUE_RATIO = keccak256("QUEUE_RATIO");

    /// @notice Circuit breaker reason: accounting stale.
    bytes32 public constant ACCOUNTING_STALE = keccak256("ACCOUNTING_STALE");

    /// @notice Basis points denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum total assets allowed.
    uint256 public depositCap;

    /// @notice Minimum withdrawal amount in assets.
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
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the SafetyModule with initial configuration.
    /// @param admin The default admin address.
    /// @param guardian The guardian address.
    /// @param core The core address allowed to call checks.
    /// @param depositCap_ The initial deposit cap.
    /// @param minRateDropBps_ The minimum rate drop threshold in basis points.
    /// @param maxQueueRatioBps_ The maximum queue ratio threshold in basis points.
    /// @param maxAccountingDelay_ The maximum accounting delay in seconds.
    constructor(
        address admin,
        address guardian,
        address core,
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
        if (core == address(0)) {
            revert SafetyModule__ZeroAddress("core");
        }

        depositCap = depositCap_;
        withdrawalMinimum = 0;
        minRateDropBps = minRateDropBps_;
        maxQueueRatioBps = maxQueueRatioBps_;
        maxAccountingDelay = maxAccountingDelay_;
        lastAccountingTimestamp = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(CORE_ROLE, core);

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
    function checkRateDrop(uint256 oldRate, uint256 nextRate) external override onlyRole(CORE_ROLE) {
        // solhint-disable-next-line gas-strict-inequalities
        if (nextRate >= oldRate) {
            return;
        }

        if (oldRate == 0) {
            _triggerBreaker(RATE_DROP);
            return;
        }

        uint256 dropBps = (oldRate - nextRate) * BPS_DENOMINATOR / oldRate;
        // solhint-disable-next-line gas-strict-inequalities
        if (dropBps >= minRateDropBps) {
            _triggerBreaker(RATE_DROP);
        }
    }

    /// @inheritdoc ISafetyModule
    function checkQueueRatio(uint256 queued, uint256 total) external override onlyRole(CORE_ROLE) {
        if (total == 0) {
            if (queued > 0) {
                _triggerBreaker(QUEUE_RATIO);
            }
            return;
        }

        uint256 ratioBps = (queued * BPS_DENOMINATOR) / total;
        // solhint-disable-next-line gas-strict-inequalities
        if (ratioBps >= maxQueueRatioBps) {
            _triggerBreaker(QUEUE_RATIO);
        }
    }

    /// @inheritdoc ISafetyModule
    function checkAccountingLiveness() external override onlyRole(CORE_ROLE) {
        // slither-disable-next-line timestamp
        // solhint-disable-next-line gas-strict-inequalities
        if (block.timestamp <= lastAccountingTimestamp) {
            return;
        }

        uint256 elapsed = block.timestamp - lastAccountingTimestamp;
        // slither-disable-next-line timestamp
        if (elapsed > maxAccountingDelay) {
            _triggerBreaker(ACCOUNTING_STALE);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISafetyModule
    function setDepositCap(uint256 cap) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    /// @inheritdoc ISafetyModule
    function setWithdrawalMinimum(uint256 minimum) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        withdrawalMinimum = minimum;
        emit WithdrawalMinimumUpdated(minimum);
    }

    /// @inheritdoc ISafetyModule
    function setMinRateDropBps(uint256 minRateDropBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        minRateDropBps = minRateDropBps_;
        emit RateDropLimitUpdated(minRateDropBps_);
    }

    /// @inheritdoc ISafetyModule
    function setMaxQueueRatioBps(uint256 maxQueueRatioBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        maxQueueRatioBps = maxQueueRatioBps_;
        emit QueueRatioLimitUpdated(maxQueueRatioBps_);
    }

    /// @inheritdoc ISafetyModule
    function setMaxAccountingDelay(uint256 maxAccountingDelay_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        maxAccountingDelay = maxAccountingDelay_;
        emit AccountingDelayUpdated(maxAccountingDelay_);
    }

    /// @inheritdoc ISafetyModule
    function setLastAccountingTimestamp(uint256 lastAccountingTimestamp_) external override onlyRole(CORE_ROLE) {
        lastAccountingTimestamp = lastAccountingTimestamp_;
        emit AccountingTimestampUpdated(lastAccountingTimestamp_);
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
        onlyRole(CORE_ROLE)
        returns (bool allowed)
    {
        if (deposit + total > depositCap) {
            return false;
        }
        return true;
    }

    /// @inheritdoc ISafetyModule
    function checkWithdrawalMinimum(uint256 assets) external view override onlyRole(CORE_ROLE) {
        if (assets < withdrawalMinimum) {
            revert SafetyModule__BelowWithdrawalMinimum(assets, withdrawalMinimum);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _triggerBreaker(bytes32 reason) internal {
        emit CircuitBreakerTriggered(reason);
        if (!paused) {
            paused = true;
            emit Paused();
        }
    }
}
