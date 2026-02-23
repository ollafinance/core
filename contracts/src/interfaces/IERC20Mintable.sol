// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

/// @title IERC20Mintable
/// @notice Interface for mintable ERC-20 tokens.
/// @author Olla Core contributors
interface IERC20Mintable {
    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints tokens to the recipient.
    /// @param to The recipient address.
    /// @param amount The token amount to mint.
    function mint(address to, uint256 amount) external;
}
