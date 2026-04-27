// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { Address } from "@oz/utils/Address.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { IMaliciousSafetyModule } from "src/safetymodule/mocks/IMaliciousSafetyModule.sol";

/// @title MaliciousSafetyModule
/// @notice Test-only safety module that attempts reentrancy during checkAccountingLiveness.
/// @author Olla Core contributors
contract MaliciousSafetyModule is IMaliciousSafetyModule, ISafetyModule {
    using Address for address;

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
    address private _reentryTarget;
    bytes private _reentryCalldata;
    bool private _reenterOnCheckAccountingLiveness;

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the MaliciousSafetyModule.
    /// @param coreAddress The core contract address.
    /// @param vaultAddress The vault contract address.
    constructor(address coreAddress, address vaultAddress) {
        CORE_ADDRESS = coreAddress;
        VAULT_ADDRESS = vaultAddress;
    }

    /*//////////////////////////////////////////////////////////////
                          CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure re-entry target and calldata.
    /// @param target The contract to call during re-entry.
    /// @param data The calldata to use.
    function setReentry(address target, bytes calldata data) external override(IMaliciousSafetyModule) {
        _reentryTarget = target;
        _reentryCalldata = data;
    }

    /// @notice Enable or disable re-entry on checkAccountingLiveness.
    /// @param enabled Whether to enable the reentrancy attempt.
    function setReenterOnCheckAccountingLiveness(bool enabled) external override(IMaliciousSafetyModule) {
        _reenterOnCheckAccountingLiveness = enabled;
    }

    /// @notice Marks the module as paused.
    function pause() external override {
        _paused = true;
    }

    /// @notice Marks the module as unpaused.
    function unpause() external override {
        _paused = false;
    }

    /// @notice Attempts re-entry when called, then acts as no-op.
    function checkAccountingLiveness() external override {
        if (_reenterOnCheckAccountingLiveness) {
            _reenterOnCheckAccountingLiveness = false;
            _reentryTarget.functionCall(_reentryCalldata);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns whether the mock is paused.
    /// @return pausedState True if paused.
    function isPaused() external view override returns (bool pausedState) {
        return _paused;
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

    /*//////////////////////////////////////////////////////////////
                       PURE NO-OP FUNCTIONS
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

    /// @notice Always allow deposits in tests.
    /// @param deposit The incoming deposit amount.
    /// @param total The current total assets.
    /// @return allowed True when deposits are allowed.
    function checkDepositAllowed(uint256 deposit, uint256 total) external pure override returns (bool allowed) {
        _noop(deposit + total);
        return true;
    }

    /// @notice Returns max uint256 deposit cap for tests.
    /// @return The deposit cap.
    function depositCap() external pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @notice No-op withdrawal minimum check for tests.
    /// @param shares The withdrawal amount in shares.
    function checkWithdrawalMinimum(uint256 shares) external pure override {
        _noop(shares);
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
