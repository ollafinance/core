// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {IERC20} from "@oz/token/ERC20/IERC20.sol";

import {IStakingManager} from "src/interfaces/IStakingManager.sol";
import {IStAztec} from "src/interfaces/IStAztec.sol";

/// @title IOllaCore
/// @notice Interface for the OllaCore vault with async withdrawals.
/// @author Olla Core contributors
interface IOllaCore {
    struct PendingWithdrawal {
        uint256 shares;
        uint256 assets;
        address receiver;
    }

    // solhint-disable gas-indexed-events
    /// @notice Emitted when a deposit is completed.
    /// @param caller The address that initiated the deposit.
    /// @param receiver The address receiving the shares.
    /// @param assets The assets deposited.
    /// @param shares The shares minted.
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when a withdrawal is completed.
    /// @param caller The address that initiated the withdrawal.
    /// @param receiver The address receiving the assets.
    /// @param owner The share owner.
    /// @param assets The assets withdrawn.
    /// @param shares The shares burned.
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Emitted when a withdrawal request is created.
    /// @param owner The share owner that requested the withdrawal.
    /// @param receiver The address receiving the assets.
    /// @param assets The assets requested.
    /// @param shares The shares burned.
    event RequestWithdraw(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when a redeem request is created.
    /// @param owner The share owner that requested the redemption.
    /// @param receiver The address receiving the assets.
    /// @param assets The assets requested.
    /// @param shares The shares burned.
    event RequestRedeem(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when a redeem request is claimed.
    /// @param owner The share owner that requested the redemption.
    /// @param receiver The address receiving the assets.
    /// @param assets The assets paid out.
    /// @param shares The shares burned.
    event ClaimRedeem(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when a stake message is sent to the staking manager.
    /// @param messageId Monotonic message id.
    /// @param amount The amount requested to stake.
    event StakeRequested(uint256 indexed messageId, uint256 amount);

    /// @notice Emitted when an unstake message is sent to the staking manager.
    /// @param messageId Monotonic message id.
    /// @param amount The amount requested to unstake.
    event UnstakeRequested(uint256 indexed messageId, uint256 amount);
    // solhint-enable gas-indexed-events

    /// @notice Initializes the vault with the Aztec asset address.
    /// @param asset_ The underlying Aztec asset.
    /// @param stAztec_ The stAztec share token.
    /// @param stakingManager_ The staking manager for delegation messaging.
    function initialize(IERC20 asset_, IStAztec stAztec_, IStakingManager stakingManager_) external;

    /// @notice Deposits assets and mints stAztec shares.
    /// @param assets The amount of assets to deposit.
    /// @param receiver The recipient of the stAztec shares.
    /// @return shares The shares minted to the receiver.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Requests a redemption in shares.
    /// @param shares The number of shares to redeem.
    /// @param receiver The receiver of the assets.
    /// @param owner The owner of the shares.
    /// @return assets The assets expected from the redemption.
    function requestRedeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Claims a pending withdrawal for an owner.
    /// @param owner The owner of the pending withdrawal.
    /// @return assets The assets transferred to the receiver.
    function claimPendingWithdraw(address owner) external returns (uint256 assets);

    /// @notice Returns the underlying asset address.
    /// @return The underlying asset address.
    function asset() external view returns (address);

    /// @notice Returns the stAztec share token address.
    /// @return The stAztec share token address.
    function stAztec() external view returns (address);

    /// @notice Returns the staking manager address.
    /// @return The staking manager address.
    function stakingManager() external view returns (address);

    /// @notice Returns the current total assets held by the vault.
    /// @return The total assets held by the vault.
    function totalAssets() external view returns (uint256);

    /// @notice Returns the current exchange rate in 18-decimal fixed-point units.
    /// @return The exchange rate scaled by 1e18.
    function exchangeRate() external view returns (uint256);

    /// @notice Returns the pending withdrawal for an owner.
    /// @param owner The owner to query.
    /// @return The pending withdrawal details.
    function pendingWithdrawal(address owner) external view returns (PendingWithdrawal memory);
}
