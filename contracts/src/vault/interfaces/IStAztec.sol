// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20Metadata } from "@oz/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

/// @title IStAztec
/// @notice Interface for the stAztec liquid staking token.
/// @author Olla Core contributors
interface IStAztec is IERC20, IERC20Metadata, IERC20Permit {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a zero address is provided.
    error StAztecZeroAddress();

    /// @notice Thrown when the caller is not the authorized OllaVault contract.
    error StAztec__Unauthorized();

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints stAztec shares to an account.
    /// @param to The recipient address.
    /// @param amount The amount of shares to mint.
    function mint(address to, uint256 amount) external;

    /// @notice Burns stAztec shares from an account.
    /// @param from The account to burn shares from.
    /// @param amount The amount of shares to burn.
    function burn(address from, uint256 amount) external;

    /// @notice Spends an ERC-20 allowance on behalf of the authorized OllaVault.
    /// @param owner The account that granted the allowance.
    /// @param spender The account whose allowance is consumed.
    /// @param amount The amount of allowance to spend.
    function spendAllowance(address owner, address spender, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                               VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the immutable OllaVault address authorized to mint and burn.
    /// @return The OllaVault contract address.
    function OLLA_VAULT() external view returns (address);
}
