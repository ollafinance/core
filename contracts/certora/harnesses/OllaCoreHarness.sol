// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";

/// @title OllaCoreHarness
/// @notice Exposes internal accounting state for Certora verification.
contract OllaCoreHarness is OllaCore {
    /// @notice Returns the current rebalance step as a uint8.
    function getRebalanceStep() external view returns (uint8) {
        return uint8(this.rebalanceProgress().step);
    }

    /// @notice Returns the staked principal from accounting state.
    function getStakedPrincipal() external view returns (uint256) {
        return this.accountingState().stakedPrincipal;
    }

    /// @notice Returns the rewards accumulator balance from accounting state.
    function getRewardsAccumulatorBalance() external view returns (uint256) {
        return this.accountingState().rewardsAccumulatorBalance;
    }

    /// @notice Returns the claimable rewards from accounting state.
    function getClaimableRewards() external view returns (uint256) {
        return this.accountingState().claimableRewards;
    }

    /// @notice Returns the stAztec total supply for Certora state constraints.
    function getTotalSupply() external view returns (uint256) {
        return IStAztec(this.stAztec()).totalSupply();
    }

    /// @notice Returns the cumulative deposits from flow counters.
    function getCumulativeDeposits() external view returns (uint256) {
        return this.flowCounters().cumulativeDeposits;
    }

    /// @notice Returns the cumulative withdrawals from flow counters.
    function getCumulativeWithdrawals() external view returns (uint256) {
        return this.flowCounters().cumulativeWithdrawals;
    }

    /// @notice Returns the latest report total assets.
    function getLatestReportTotalAssets() external view returns (uint256) {
        return this.latestReport().totalAssets;
    }

    /// @notice Returns the latest report exchange rate.
    function getLatestReportExchangeRate() external view returns (uint256) {
        return this.latestReport().exchangeRate;
    }

    /// @notice Returns the latest report timestamp.
    function getLatestReportTimestamp() external view returns (uint256) {
        return this.latestReport().timestamp;
    }

    /// @notice Returns the latest-report snapshot of cumulative deposits.
    /// @dev The latestReportCumulativeDeposits field comes from _flowCounters storage,
    ///      not from external calls. flowCounters() only overwrites cumulative* fields.
    function getLatestReportCumulativeDeposits() external view returns (uint256) {
        return this.flowCounters().latestReportCumulativeDeposits;
    }

    /// @notice Returns the latest-report snapshot of cumulative withdrawals.
    /// @dev The latestReportCumulativeWithdrawals field comes from _flowCounters storage,
    ///      not from external calls. flowCounters() only overwrites cumulative* fields.
    function getLatestReportCumulativeWithdrawals() external view returns (uint256) {
        return this.flowCounters().latestReportCumulativeWithdrawals;
    }
}
