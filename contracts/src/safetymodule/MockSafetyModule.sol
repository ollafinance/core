// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

/// @title MockSafetyModule
/// @notice Test stub that allows all safety checks.
/// @author Olla Core contributors
contract MockSafetyModule is ISafetyModule {
    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    bool internal _paused;

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

    /// @notice Returns whether the mock is paused.
    /// @return pausedState True if paused.
    function isPaused() external view override returns (bool pausedState) {
        return _paused;
    }

    /// @notice No-op rate drop check for tests.
    /// @param oldRate The previous exchange rate.
    /// @param nextRate The next exchange rate.
    function checkRateDrop(uint256 oldRate, uint256 nextRate) external pure override {
        _noop(oldRate + nextRate);
    }

    /// @notice No-op queue ratio check for tests.
    /// @param queued The queued withdrawal assets.
    /// @param total The current total assets.
    function checkQueueRatio(uint256 queued, uint256 total) external pure override {
        _noop(queued + total);
    }

    /// @notice No-op accounting liveness check for tests.
    function checkAccountingLiveness() external pure override {
        _noop(0);
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
    /// @param minimum The new withdrawal minimum.
    function setWithdrawalMinimum(uint256 minimum) external pure override {
        _noop(minimum);
    }

    /// @notice No-op rate-drop threshold setter for tests.
    /// @param minRateDropBps The minimum rate-drop in basis points.
    function setMinRateDropBps(uint256 minRateDropBps) external pure override {
        _noop(minRateDropBps);
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
    /// @param lastAccountingTimestamp The accounting timestamp.
    function setLastAccountingTimestamp(uint256 lastAccountingTimestamp) external pure override {
        _noop(lastAccountingTimestamp);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Always allow deposits in tests.
    /// @param deposit The incoming deposit amount.
    /// @param total The current total assets.
    /// @return allowed True when deposits are allowed.
    function checkDepositAllowed(uint256 deposit, uint256 total) external pure override returns (bool allowed) {
        _noop(deposit + total);
        return true;
    }

    /// @notice No-op withdrawal minimum check for tests.
    /// @param assets The withdrawal amount in assets.
    function checkWithdrawalMinimum(uint256 assets) external pure override {
        _noop(assets);
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
