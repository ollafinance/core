// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

/// @title MockSafetyModule
/// @notice Test stub that allows all safety checks by default, with opt-in enforcement.
/// @dev All thresholds default to 0 (disabled). Tests can enable specific circuit breakers
///      via the `mockSet*` helpers without breaking existing consumers.
/// @author Olla Core contributors
contract MockSafetyModule is ISafetyModule {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The core contract address.
    address public immutable CORE_ADDRESS;

    /// @notice The vault contract address.
    address public immutable VAULT_ADDRESS;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    bool internal _paused;

    /// @notice Tracks whether the current pause should still allow deposits.
    bool public mockDepositPaused;

    /*//////////////////////////////////////////////////////////////
                        CONFIGURABLE THRESHOLDS
    //////////////////////////////////////////////////////////////*/

    /// @notice When set > 0, checkRateDrop pauses if rate dropped by >= this (in bps).
    uint256 public mockMinRateDropBps;

    /// @notice When set > 0, checkQueueRatio pauses if queue ratio >= this (in bps).
    uint256 public mockMaxQueueRatioBps;

    /// @notice When set > 0, checkAccountingLiveness pauses if block.timestamp exceeds
    ///         mockLatestAccountingTimestamp + mockMaxAccountingDelay.
    uint256 public mockLatestAccountingTimestamp;
    uint256 public mockMaxAccountingDelay;

    /// @notice When set > 0, checkDepositAllowed enforces a cap (deposit + total <= cap).
    uint256 public mockDepositCapEnforced;

    /// @notice When set > 0, checkWithdrawalMinimum reverts if shares < this.
    uint256 public mockWithdrawalMinimumShares;

    /*//////////////////////////////////////////////////////////////
                            CALL COUNTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Count of calls to state-mutating check functions (for verification).
    /// @dev checkDepositAllowed and checkWithdrawalMinimum are view in the interface,
    ///      so they cannot increment counters on-chain.
    uint256 public checkRateDropCallCount;
    uint256 public checkQueueRatioCallCount;
    uint256 public checkAccountingLivenessCallCount;

    /*//////////////////////////////////////////////////////////////
                         LAST ARGUMENT CAPTURE
    //////////////////////////////////////////////////////////////*/

    /// @notice Last arguments passed to checkRateDrop.
    uint256 public lastOldRate;
    uint256 public lastNextRate;

    /// @notice Last arguments passed to checkQueueRatio.
    uint256 public lastQueued;
    uint256 public lastTotal;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the MockSafetyModule.
    /// @param coreAddress The core contract address.
    /// @param vaultAddress The vault contract address.
    constructor(address coreAddress, address vaultAddress) {
        CORE_ADDRESS = coreAddress;
        VAULT_ADDRESS = vaultAddress;
    }

    /*//////////////////////////////////////////////////////////////
                          MOCK CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    // solhint-disable comprehensive-interface

    /// @notice Sets the rate-drop threshold for mock enforcement.
    /// @param bps The minimum rate-drop in basis points. Set 0 to disable.
    function mockSetMinRateDropBps(uint256 bps) external {
        mockMinRateDropBps = bps;
    }

    /// @notice Sets the queue ratio threshold for mock enforcement.
    /// @param bps The maximum queue ratio in basis points. Set 0 to disable.
    function mockSetMaxQueueRatioBps(uint256 bps) external {
        mockMaxQueueRatioBps = bps;
    }

    /// @notice Sets the accounting liveness parameters for mock enforcement.
    /// @param latestTimestamp The latest accounting timestamp.
    /// @param maxDelay The maximum allowed delay. Set both > 0 to enable.
    function mockSetAccountingLiveness(uint256 latestTimestamp, uint256 maxDelay) external {
        mockLatestAccountingTimestamp = latestTimestamp;
        mockMaxAccountingDelay = maxDelay;
    }

    /// @notice Sets the deposit cap for mock enforcement.
    /// @param cap The cap value. Set 0 to disable.
    function mockSetDepositCap(uint256 cap) external {
        mockDepositCapEnforced = cap;
    }

    /// @notice Sets the withdrawal minimum for mock enforcement.
    /// @param minimum The minimum shares. Set 0 to disable.
    function mockSetWithdrawalMinimum(uint256 minimum) external {
        mockWithdrawalMinimumShares = minimum;
    }

    /// @notice Sets whether a mock pause blocks deposits.
    /// @param value True to block deposits while paused.
    function mockSetDepositPaused(bool value) external {
        mockDepositPaused = value;
    }

    // solhint-enable comprehensive-interface

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Marks the module as paused.
    function pause() external override {
        _paused = true;
    }

    /// @notice Marks the module as unpaused.
    function unpause() external override {
        _paused = false;
    }

    /// @notice Rate drop check with optional enforcement for tests.
    /// @param oldRate The previous exchange rate.
    /// @param nextRate The next exchange rate.
    function checkRateDrop(uint256 oldRate, uint256 nextRate) external override {
        ++checkRateDropCallCount;
        lastOldRate = oldRate;
        lastNextRate = nextRate;

        if (mockMinRateDropBps > 0 && nextRate < oldRate && oldRate > 0) {
            uint256 dropBps = (oldRate - nextRate) * BPS_DENOMINATOR / oldRate;
            if (dropBps >= mockMinRateDropBps) {
                _paused = true;
                emit CircuitBreakerTriggered(BreakerReason.RateDrop);
                emit Paused();
            }
        }
    }

    /// @notice Queue ratio check with optional enforcement for tests.
    /// @param queued The queued withdrawal assets.
    /// @param total The current total assets.
    function checkQueueRatio(uint256 queued, uint256 total) external override {
        ++checkQueueRatioCallCount;
        lastQueued = queued;
        lastTotal = total;

        if (mockMaxQueueRatioBps > 0) {
            // `total` is totalAssets() which already subtracts pending withdrawals,
            // so the gross total is `queued + total`.
            uint256 gross = queued + total;
            if (gross == 0) {
                return;
            }
            uint256 ratioBps = (queued * BPS_DENOMINATOR) / gross;
            if (ratioBps >= mockMaxQueueRatioBps) {
                _paused = true;
                emit CircuitBreakerTriggered(BreakerReason.QueueRatio);
                emit Paused();
            }
        }
    }

    /// @notice Accounting liveness check with optional enforcement for tests.
    function checkAccountingLiveness() external override {
        ++checkAccountingLivenessCallCount;

        if (mockMaxAccountingDelay > 0 && mockLatestAccountingTimestamp > 0) {
            if (block.timestamp > mockLatestAccountingTimestamp) {
                uint256 elapsed = block.timestamp - mockLatestAccountingTimestamp;
                if (elapsed > mockMaxAccountingDelay) {
                    _paused = true;
                    emit CircuitBreakerTriggered(BreakerReason.AccountingStale);
                    emit Paused();
                }
            }
        }
    }

    /// @notice Returns whether the mock is paused.
    /// @return pausedState True if paused.
    function isPaused() external view override returns (bool pausedState) {
        return _paused;
    }

    /// @notice Returns whether deposits should be blocked by the mock pause.
    /// @return pausedState True when deposits should be blocked.
    function isDepositPaused() external view override returns (bool pausedState) {
        return _paused && mockDepositPaused;
    }

    // solhint-disable func-name-mixedcase
    /// @notice Returns the core address.
    /// @return The core contract address.
    function CORE() external view override returns (address) {
        return CORE_ADDRESS;
    }

    /// @notice Returns the vault address.
    /// @return The vault contract address.
    function VAULT() external view override returns (address) {
        return VAULT_ADDRESS;
    }

    // solhint-enable func-name-mixedcase

    /// @notice Deposit check with optional cap enforcement for tests.
    /// @param deposit The incoming deposit amount.
    /// @param total The current total assets.
    /// @return allowed True when deposits are allowed.
    function checkDepositAllowed(uint256 deposit, uint256 total) external view override returns (bool allowed) {
        if (mockDepositCapEnforced > 0) {
            if (deposit > mockDepositCapEnforced || total > mockDepositCapEnforced - deposit) {
                return false;
            }
        }
        return true;
    }

    /// @notice Returns the deposit cap for tests.
    /// @return The deposit cap.
    function depositCap() external view override returns (uint256) {
        if (mockDepositCapEnforced > 0) {
            return mockDepositCapEnforced;
        }
        return type(uint256).max;
    }

    /// @notice Withdrawal minimum check with optional enforcement for tests.
    /// @param shares The withdrawal amount in shares.
    function checkWithdrawalMinimum(uint256 shares) external view override {
        if (mockWithdrawalMinimumShares > 0 && shares < mockWithdrawalMinimumShares) {
            revert SafetyModule__BelowWithdrawalMinimum(shares, mockWithdrawalMinimumShares);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice No-op deposit cap setter for tests.
    /// @param cap The new deposit cap.
    function setDepositCap(uint256 cap) external pure override {
        _noop(cap);
    }

    /// @notice No-op withdrawal minimum setter for tests.
    /// @param minimumShares The new withdrawal minimum in shares.
    function setWithdrawalMinimum(uint256 minimumShares) external pure override {
        _noop(minimumShares);
    }

    /// @notice No-op rate-drop threshold setter for tests.
    /// @param minRateDropBps The minimum rate-drop in basis points.
    function setMinRateDropBps(uint256 minRateDropBps) external pure override {
        _noop(minRateDropBps);
    }

    /// @notice No-op high-water mark setter for tests.
    /// @param rateHighWaterMark The new high-water mark.
    function setRateHighWaterMark(uint256 rateHighWaterMark) external pure override {
        _noop(rateHighWaterMark);
    }

    /// @notice No-op queue ratio threshold setter for tests.
    /// @param maxQueueRatioBps The maximum queue ratio in basis points.
    function setMaxQueueRatioBps(uint256 maxQueueRatioBps) external pure override {
        _noop(maxQueueRatioBps);
    }

    /// @notice No-op accounting delay setter for tests.
    /// @param maxAccountingDelay The maximum accounting delay.
    function setMaxAccountingDelay(uint256 maxAccountingDelay) external pure override {
        _noop(maxAccountingDelay);
    }

    /// @notice No-op accounting timestamp setter for tests.
    /// @param latestAccountingTimestamp The accounting timestamp.
    function setLatestAccountingTimestamp(uint256 latestAccountingTimestamp) external pure override {
        _noop(latestAccountingTimestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _noop(uint256 value) internal pure {
        unchecked {
            uint256 temp = value;
            ++temp;
            --temp;
            if (temp == type(uint256).max) {
                temp = 0;
            }
        }
    }
}
