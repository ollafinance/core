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

    /// @notice Thrown when the caller is not the authorized OllaCore contract.
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

    /*//////////////////////////////////////////////////////////////
                               VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the immutable OllaCore address authorized to mint and burn.
    /// @return The OllaCore contract address.
    function OLLA_CORE() external view returns (address);
}
