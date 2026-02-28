// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { ERC20 } from "@oz/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@oz/token/ERC20/extensions/ERC20Permit.sol";
import { IERC20Metadata } from "@oz/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";

import { IStAztec } from "src/core/interfaces/IStAztec.sol";

/// @title StAztec
/// @notice ERC-20 token representing staked Aztec shares in OllaCore.
/// @author Olla Core contributors
contract StAztec is ERC20Permit, IStAztec {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 private constant _DECIMALS = 18;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The immutable OllaVault address authorized to mint and burn.
    address public immutable OLLA_VAULT;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the immutable OllaVault address.
    /// @param ollaVault_ The OllaVault proxy address authorized to mint and burn.
    constructor(address ollaVault_) ERC20("stAztec", "stAZTEC") ERC20Permit("stAztec") {
        if (ollaVault_ == address(0)) {
            revert StAztecZeroAddress();
        }
        OLLA_VAULT = ollaVault_;
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints stAztec shares to an account.
    /// @param to The recipient address.
    /// @param amount The amount of shares to mint.
    function mint(address to, uint256 amount) external override {
        if (msg.sender != OLLA_VAULT) revert StAztec__Unauthorized();
        _mint(to, amount);
    }

    /// @notice Burns stAztec shares from an account.
    /// @param from The account to burn shares from.
    /// @param amount The amount of shares to burn.
    function burn(address from, uint256 amount) external override {
        if (msg.sender != OLLA_VAULT) revert StAztec__Unauthorized();
        _burn(from, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current permit nonce for an owner.
    /// @param owner The address to query.
    /// @return The current permit nonce.
    function nonces(address owner) public view override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    /// @notice Returns the decimals used by the token.
    /// @return The number of decimals for the token.
    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return _DECIMALS;
    }
}
