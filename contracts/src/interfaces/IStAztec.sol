// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title IStAztec
/// @notice Interface for the stAztec liquid staking token.
/// @author Olla Core contributors
interface IStAztec {
    /// @notice Mints stAztec shares to an account.
    /// @param to The recipient address.
    /// @param amount The amount of shares to mint.
    function mint(address to, uint256 amount) external;

    /// @notice Burns stAztec shares from an account.
    /// @param from The account to burn shares from.
    /// @param amount The amount of shares to burn.
    function burn(address from, uint256 amount) external;
}
