// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

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
    // solhint-enable gas-indexed-events

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
     //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not authorized.
    error WithdrawalQueue__Unauthorized(address caller);

    /// @notice Thrown when a zero address is provided.
    error WithdrawalQueue__ZeroAddress(string param);

    /// @notice Thrown when a zero amount is provided.
    error WithdrawalQueue__ZeroAmount(string param);

    /// @notice Thrown when a request is not finalized.
    error WithdrawalQueue__NotFinalized(uint256 id);

    /// @notice Thrown when a request is already claimed.
    error WithdrawalQueue__AlreadyClaimed(uint256 id);

    /// @notice Thrown when a request id is invalid.
    error WithdrawalQueue__InvalidRequest(uint256 id);

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the queue.
    /// @param core_ OllaCore address.
    /// @param admin_ Default admin role address.
    function initialize(address core_, address admin_) external;

    /// @notice Enqueues a new withdrawal request.
    /// @param recipient The request owner.
    /// @param shares The shares burned for the request.
    /// @param assetsExpected The assets expected when finalized.
    /// @param rate The exchange rate locked at request time.
    /// @return requestId The request id.
    function requestWithdrawal(address recipient, uint256 shares, uint256 assetsExpected, uint256 rate)
        external
        returns (uint256 requestId);

    /// @notice Finalizes withdrawals using available liquidity.
    /// @param available The available assets to finalize.
    /// @return used The assets used for finalization.
    function finalizeWithdrawals(uint256 available) external returns (uint256 used);

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
    function nextRequestId() external view returns (uint256 requestId);

    /// @notice Returns the next pending request id to finalize.
    /// @return requestId The next pending request id.
    function nextPendingId() external view returns (uint256 requestId);

    /// @notice Returns the total pending assets.
    /// @return totalPending The total assets for unfinalized requests.
    function totalPendingAssets() external view returns (uint256 totalPending);

    /// @notice Returns the request struct for a given id.
    /// @param id The request id.
    /// @return request The request struct.
    function getRequest(uint256 id) external view returns (WithdrawalRequest memory request);

    /// @notice Returns the next unfinalized request id.
    /// @return requestId The next unfinalized request id.
    function nextUnfinalized() external view returns (uint256 requestId);

    /// @notice Previews assets used for withdrawal finalization.
    /// @param available The available assets to finalize.
    /// @return used The assets that would be used.
    function previewFinalizeWithdrawals(uint256 available) external view returns (uint256 used);

    /// @notice Returns the core address.
    /// @return The core contract address.
    function core() external view returns (address);
}
