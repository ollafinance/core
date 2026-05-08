// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaVaultHarness
/// @notice Exposes internal state for Certora verification without modifying production code.
/// @dev Harness getters use public view functions where available. Internal queue state
///      (per-request fields, request owners) is exposed via try/catch wrappers so that
///      lookups for non-existent ids return zero rather than reverting under the prover.
contract OllaVaultHarness is OllaVault {
    /// @notice Returns the cumulative deposits counter.
    function getCumulativeDeposits() external view returns (uint256) {
        return cumulativeDeposits;
    }

    /// @notice Returns the cumulative withdrawals counter.
    function getCumulativeWithdrawals() external view returns (uint256) {
        return cumulativeWithdrawals;
    }

    /// @notice Returns the cumulative slashing adjustments counter.
    function getCumulativeSlashingAdjustments() external view returns (uint256) {
        return cumulativeSlashingAdjustments;
    }

    /// @notice Returns core's convertToShares result for given assets.
    function coreConvertToShares(uint256 assets) external view returns (uint256) {
        return IOllaCore(this.core()).convertToShares(assets);
    }

    /// @notice Returns core's convertToAssets result for given shares.
    function coreConvertToAssets(uint256 shares) external view returns (uint256) {
        return IOllaCore(this.core()).convertToAssets(shares);
    }

    /// @notice Returns core's convertToAssetsCeil result for given shares.
    function coreConvertToAssetsCeil(uint256 shares) external view returns (uint256) {
        return IOllaCore(this.core()).convertToAssetsCeil(shares);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL QUEUE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns whether a specific request exists and is finalized.
    /// @dev Returns false if the request doesn't exist (getWithdrawalRequest reverts).
    function isFinalized(uint256 id) external view returns (bool) {
        try this.getWithdrawalRequest(id) returns (IOllaVault.WithdrawalRequest memory req) {
            return req.finalized;
        } catch {
            return false;
        }
    }

    /// @notice Returns the assetsExpected for a specific request, or 0 if not found.
    function getRequestAssets(uint256 id) external view returns (uint256) {
        try this.getWithdrawalRequest(id) returns (IOllaVault.WithdrawalRequest memory req) {
            return req.assetsExpected;
        } catch {
            return 0;
        }
    }

    /// @notice Returns the shares for a specific request, or 0 if not found.
    function getRequestShares(uint256 id) external view returns (uint256) {
        try this.getWithdrawalRequest(id) returns (IOllaVault.WithdrawalRequest memory req) {
            return req.shares;
        } catch {
            return 0;
        }
    }

    /// @notice Returns the locked rate for a specific request, or 0 if not found.
    function getRequestRate(uint256 id) external view returns (uint256) {
        try this.getWithdrawalRequest(id) returns (IOllaVault.WithdrawalRequest memory req) {
            return req.rate;
        } catch {
            return 0;
        }
    }
}
