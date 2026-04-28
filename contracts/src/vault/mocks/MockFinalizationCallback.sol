// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IFinalizationCallback } from "src/vault/interfaces/IFinalizationCallback.sol";

/// @title MockFinalizationCallback
/// @notice Minimal IFinalizationCallback implementation used by tests that exercise the real
///         WithdrawalQueue without a real OllaVault. Records each call so tests can assert
///         that finalization fired the expected callback sequence.
/// @author Olla Core contributors
contract MockFinalizationCallback is IFinalizationCallback {
    /// @notice Number of times onWithdrawalFinalized was invoked.
    uint256 public callCount;

    /// @notice Last requestId observed in a callback.
    uint256 public lastRequestId;

    /// @notice Last shares value observed in a callback.
    uint256 public lastShares;

    /// @inheritdoc IFinalizationCallback
    function onWithdrawalFinalized(uint256 requestId, uint256 shares) external override {
        ++callCount;
        lastRequestId = requestId;
        lastShares = shares;
    }
}
