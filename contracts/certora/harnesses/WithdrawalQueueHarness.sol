// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

/// @title WithdrawalQueueHarness
/// @notice Exposes internal state for Certora verification without modifying production code.
/// @dev Harness functions use try/catch to avoid reverts that would confuse the prover.
contract WithdrawalQueueHarness is WithdrawalQueue {
    /// @notice Returns whether a specific request exists and is finalized.
    /// @dev Returns false if the request doesn't exist (getRequest reverts).
    function isFinalized(uint256 id) external view returns (bool) {
        try this.getRequest(id) returns (IWithdrawalQueue.WithdrawalRequest memory req) {
            return req.finalized;
        } catch {
            return false;
        }
    }

    /// @notice Returns the assetsExpected for a specific request, or 0 if not found.
    function getRequestAssets(uint256 id) external view returns (uint256) {
        try this.getRequest(id) returns (IWithdrawalQueue.WithdrawalRequest memory req) {
            return req.assetsExpected;
        } catch {
            return 0;
        }
    }

    /// @notice Returns the shares for a specific request, or 0 if not found.
    function getRequestShares(uint256 id) external view returns (uint256) {
        try this.getRequest(id) returns (IWithdrawalQueue.WithdrawalRequest memory req) {
            return req.shares;
        } catch {
            return 0;
        }
    }

    /// @notice Returns the recipient for a specific request, or address(0) if not found.
    function getRequestRecipient(uint256 id) external view returns (address) {
        try this.getRequest(id) returns (IWithdrawalQueue.WithdrawalRequest memory req) {
            return req.recipient;
        } catch {
            return address(0);
        }
    }

    /// @notice Returns whether a request exists (recipient != address(0)).
    function requestExists(uint256 id) external view returns (bool) {
        try this.getRequest(id) returns (IWithdrawalQueue.WithdrawalRequest memory) {
            return true;
        } catch {
            return false;
        }
    }
}
