// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

/// @title ISafetyModule
/// @notice Interface for deposit caps and circuit breaker checks.
/// @author Olla Core contributors
interface ISafetyModule {
    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Circuit breaker reason identifiers.
    enum BreakerReason {
        RateDrop,
        QueueRatio,
        AccountingStale
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // solhint-disable gas-indexed-events
    /// @notice Emitted when the safety module is paused.
    event Paused();

    /// @notice Emitted when the safety module is unpaused.
    event Unpaused();

    /// @notice Emitted when the deposit cap is updated.
    /// @param cap The new deposit cap.
    event DepositCapUpdated(uint256 cap);

    /// @notice Emitted when the withdrawal minimum is updated.
    /// @param minimumShares The new withdrawal minimum in shares.
    event WithdrawalMinimumUpdated(uint256 minimumShares);

    /// @notice Emitted when a circuit breaker condition is triggered.
    /// @param reason The breaker reason identifier.
    event CircuitBreakerTriggered(BreakerReason reason);

    /// @notice Emitted when the rate-drop threshold is updated.
    /// @param minRateDropBps The new rate-drop threshold in basis points.
    event RateDropLimitUpdated(uint256 minRateDropBps);

    /// @notice Emitted when the cumulative rate-drop high-water mark is updated.
    /// @param rateHighWaterMark The new rate high-water mark.
    event RateHighWaterMarkUpdated(uint256 rateHighWaterMark);

    /// @notice Emitted when the queue ratio threshold is updated.
    /// @param maxQueueRatioBps The new queue ratio threshold in basis points.
    event QueueRatioLimitUpdated(uint256 maxQueueRatioBps);

    /// @notice Emitted when the accounting delay threshold is updated.
    /// @param maxAccountingDelay The new maximum accounting delay.
    event AccountingDelayUpdated(uint256 maxAccountingDelay);

    /// @notice Emitted when the accounting timestamp is updated.
    /// @param latestAccountingTimestamp The new accounting timestamp.
    event AccountingTimestampUpdated(uint256 latestAccountingTimestamp);
    // solhint-enable gas-indexed-events

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a zero address is provided.
    error SafetyModule__ZeroAddress(string param);

    /// @notice Thrown when a withdrawal share amount is below the minimum.
    error SafetyModule__BelowWithdrawalMinimum(uint256 shares, uint256 minimumShares);

    /// @notice Thrown when caller is not authorized core.
    error SafetyModule__UnauthorizedCore(address caller);

    /// @notice Thrown when a configuration parameter is out of bounds.
    error SafetyModule__InvalidParameter();

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks whether a rate drop breaches the configured threshold.
    /// @param oldRate The previous exchange rate.
    /// @param nextRate The next exchange rate.
    function checkRateDrop(uint256 oldRate, uint256 nextRate) external;

    /// @notice Checks whether the queued ratio breaches the configured threshold.
    /// @param queued The queued withdrawal assets.
    /// @param total The current total assets.
    function checkQueueRatio(uint256 queued, uint256 total) external;

    /// @notice Checks whether accounting activity is stale.
    function checkAccountingLiveness() external;

    /*//////////////////////////////////////////////////////////////
                      PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the deposit cap.
    /// @param cap The new deposit cap.
    function setDepositCap(uint256 cap) external;

    /// @notice Updates the withdrawal minimum.
    /// @param minimumShares The new withdrawal minimum in shares.
    function setWithdrawalMinimum(uint256 minimumShares) external;

    /// @notice Updates the rate-drop threshold.
    /// @param minRateDropBps The new rate-drop threshold in basis points.
    function setMinRateDropBps(uint256 minRateDropBps) external;

    /// @notice Resets the cumulative rate-drop high-water mark after governance review.
    /// @param rateHighWaterMark The new high-water mark.
    function setRateHighWaterMark(uint256 rateHighWaterMark) external;

    /// @notice Updates the queue ratio threshold.
    /// @param maxQueueRatioBps The new queue ratio threshold in basis points.
    function setMaxQueueRatioBps(uint256 maxQueueRatioBps) external;

    /// @notice Updates the accounting delay threshold.
    /// @param maxAccountingDelay The new maximum accounting delay.
    function setMaxAccountingDelay(uint256 maxAccountingDelay) external;

    /// @notice Updates the accounting timestamp.
    /// @param latestAccountingTimestamp The new accounting timestamp.
    function setLatestAccountingTimestamp(uint256 latestAccountingTimestamp) external;

    /// @notice Pauses the safety module.
    function pause() external;

    /// @notice Unpauses the protocol after a circuit breaker trigger or manual pause.
    /// @dev Intentionally has no cooldown or condition re-check. The GUARDIAN_ROLE is trusted
    ///      to verify the triggering condition is resolved before unpausing. A mandatory cooldown
    ///      was considered but rejected because it would block quick recovery from false positive
    ///      circuit breaker trips (e.g., transient rate fluctuations during large rebalances).
    function unpause() external;

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns whether the safety module is paused.
    /// @return pausedState True if paused.
    function isPaused() external view returns (bool pausedState);

    /// @notice Checks whether a deposit is allowed under the cap.
    /// @param deposit The incoming deposit amount.
    /// @param total The current total assets.
    /// @return allowed True if the deposit is allowed.
    function checkDepositAllowed(uint256 deposit, uint256 total) external view returns (bool allowed);

    /// @notice Checks whether a withdrawal meets the minimum requirement.
    /// @param shares The withdrawal amount in shares.
    function checkWithdrawalMinimum(uint256 shares) external view;

    /// @notice Returns the deposit cap.
    /// @return The maximum total assets allowed.
    function depositCap() external view returns (uint256);

    /// @notice Returns the core address.
    /// @return The core contract address.
    function CORE() external view returns (address);

    /// @notice Returns the vault address.
    /// @return The vault contract address.
    function VAULT() external view returns (address);
}
