// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

/// @title IWithdrawalQueue
/// @notice Interface for the FIFO withdrawal queue.
/// @author Olla Core contributors
interface IWithdrawalQueue {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct WithdrawalRequest {
        address recipient;
        bool finalized;
        bool claimed;
        uint256 shares;
        uint256 assetsExpected;
        uint256 rate;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // solhint-disable gas-indexed-events
    /// @notice Emitted when a withdrawal request is enqueued.
    /// @param id The request id.
    /// @param recipient The request owner.
    /// @param shares The shares burned for the request.
    /// @param assetsExpected The assets expected when finalized.
    /// @param rate The exchange rate locked at request time.
    event WithdrawalRequested(
        uint256 indexed id, address indexed recipient, uint256 shares, uint256 assetsExpected, uint256 rate
    );

    /// @notice Emitted when a withdrawal request is finalized.
    /// @param id The request id.
    /// @param assets The assets finalized for the request.
    event WithdrawalFinalized(uint256 indexed id, uint256 assets);

    /// @notice Emitted when a withdrawal request is claimed.
    /// @param id The request id.
    /// @param recipient The request owner.
    /// @param assetsExpected The assets claimed for the request.
    event WithdrawalClaimed(uint256 indexed id, address indexed recipient, uint256 assetsExpected);

    /// @notice Emitted when a withdrawal request's payout is adjusted due to slashing.
    /// @param id The request id.
    /// @param originalAmount The original assets expected at request time.
    /// @param adjustedAmount The adjusted payout after applying the post-slash rate.
    event WithdrawalAdjusted(uint256 indexed id, uint256 originalAmount, uint256 adjustedAmount);

    /// @notice Emitted when the gas threshold is updated.
    /// @param oldThreshold The previous gas threshold.
    /// @param newThreshold The new gas threshold.
    event GasThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    // solhint-enable gas-indexed-events

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
     //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not the vault.
    error WithdrawalQueue__UnauthorizedVault(address caller);

    /// @notice Thrown when a zero address is provided.
    error WithdrawalQueue__ZeroAddress(string param);

    /// @notice Thrown when a zero amount is provided.
    error WithdrawalQueue__ZeroAmount(string param);

    /// @notice Thrown when a request is not finalized.
    error WithdrawalQueue__NotFinalized(uint256 id);

    /// @notice Thrown when a request id is invalid.
    error WithdrawalQueue__InvalidRequest(uint256 id);

    /// @notice Thrown when a configuration parameter is invalid.
    error WithdrawalQueue__InvalidParameter();

    /*//////////////////////////////////////////////////////////////
                              VAULT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the queue.
    /// @param vault_ OllaVault address.
    /// @param admin_ Default admin role address.
    /// @param gasThreshold_ Initial gas threshold for finalization loop.
    function initialize(address vault_, address admin_, uint256 gasThreshold_) external;

    /// @notice Sets the gas threshold used for the finalization loop.
    /// @param threshold The new gas threshold.
    function setGasThreshold(uint256 threshold) external;

    /// @notice Enqueues a new withdrawal request.
    /// @param recipient The request owner.
    /// @param shares The shares burned for the request.
    /// @param assetsExpected The assets expected when finalized.
    /// @param rate The exchange rate locked at request time.
    /// @return requestId The request id.
    function requestWithdrawal(address recipient, uint256 shares, uint256 assetsExpected, uint256 rate)
        external
        returns (uint256 requestId);

    /// @notice Finalizes withdrawals using available liquidity up to, but not including, `maxRequestId`.
    /// @param available The available assets to finalize.
    /// @param currentRate The current exchange rate; used to adjust payouts after slashing.
    ///        Pass 0 to skip adjustment (e.g., from mocks).
    /// @param maxRequestId The exclusive request id upper bound for this finalization pass.
    /// @return used The assets used for finalization.
    /// @return finalizedCount The number of requests finalized.
    /// @return totalAdjusted The total reduction applied to requests due to slashing.
    function finalizeWithdrawals(uint256 available, uint256 currentRate, uint256 maxRequestId)
        external
        returns (uint256 used, uint256 finalizedCount, uint256 totalAdjusted);

    /// @notice Marks a finalized request as claimed.
    /// @param id The request id.
    /// @return assetsExpected The assets expected for the request.
    function claimWithdrawal(uint256 id) external returns (uint256 assetsExpected);

    /*//////////////////////////////////////////////////////////////
                      PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the next request id to assign.
    /// @return requestId The next request id.
    function nextRequestId() external view returns (uint64 requestId);

    /// @notice Returns the next pending request id to finalize.
    /// @return requestId The next pending request id.
    function nextPendingId() external view returns (uint64 requestId);

    /// @notice Returns the total pending assets.
    /// @return totalPending The total assets for unfinalized requests.
    function totalPendingAssets() external view returns (uint256 totalPending);

    /// @notice Returns the total pending shares (burned but not yet finalized).
    /// @return totalPending The total shares for unfinalized requests.
    function totalPendingShares() external view returns (uint256 totalPending);

    /// @notice Returns the request struct for a given id.
    /// @param id The request id.
    /// @return request The request struct.
    function getRequest(uint256 id) external view returns (WithdrawalRequest memory request);

    /// @notice Returns the next unfinalized request id.
    /// @return requestId The next unfinalized request id.
    function nextUnfinalized() external view returns (uint256 requestId);

    /// @notice Returns the gas threshold for the finalization loop.
    /// @return The gas threshold.
    function gasThreshold() external view returns (uint32);

    /// @notice Returns the vault address.
    /// @return The vault contract address.
    function vault() external view returns (address);
}
