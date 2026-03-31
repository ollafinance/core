// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";

/// @title OllaVaultHarness
/// @notice Exposes internal state for Certora verification without modifying production code.
/// @dev Harness getters use public view functions where available. Private state without
///      public getters (e.g., _finalizedUnclaimedAssets) is not directly exposed.
contract OllaVaultHarness is OllaVault {
    /// @notice Returns the cumulative deposits counter.
    function getCumulativeDeposits() external view returns (uint256) {
        return cumulativeDeposits;
    }

    /// @notice Returns the cumulative withdrawals counter.
    function getCumulativeWithdrawals() external view returns (uint256) {
        return cumulativeWithdrawals;
    }

    /// @notice Returns the cumulative exit fees counter.
    function getCumulativeExitFees() external view returns (uint256) {
        return cumulativeExitFees;
    }

    /// @notice Returns the cumulative slashing adjustments counter.
    function getCumulativeSlashingAdjustments() external view returns (uint256) {
        return cumulativeSlashingAdjustments;
    }

    /// @notice Returns the instant redemption fee in basis points.
    function getInstantRedemptionFeeBP() external view returns (uint256) {
        return instantRedemptionFeeBP;
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
}
