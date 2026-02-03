// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControl } from "@oz/access/AccessControl.sol";
import { ERC20 } from "@oz/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@oz/token/ERC20/extensions/ERC20Permit.sol";
import { IERC20Metadata } from "@oz/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";

import { IStAztec } from "src/core/interfaces/IStAztec.sol";
import { RolesLib } from "src/shared/RolesLib.sol";

/// @title StAztec
/// @notice ERC-20 token representing staked Aztec shares in OllaCore.
/// @author Olla Core contributors
contract StAztec is ERC20Permit, AccessControl, IStAztec {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 private constant _DECIMALS = 18;

    /// @notice Role for minting stAztec shares.
    bytes32 public constant MINTER_ROLE = RolesLib.MINTER_ROLE;
    /// @notice Role for burning stAztec shares.
    bytes32 public constant BURNER_ROLE = RolesLib.BURNER_ROLE;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets governance admin and configures the initial core roles.
    /// @param governance Address granted DEFAULT_ADMIN_ROLE to manage roles.
    /// @param ollaCore Address granted MINTER_ROLE and BURNER_ROLE.
    constructor(address governance, address ollaCore) ERC20("stAztec", "stAZTEC") ERC20Permit("stAztec") {
        if (governance == address(0) || ollaCore == address(0)) {
            revert StAztecZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(MINTER_ROLE, ollaCore);
        _grantRole(BURNER_ROLE, ollaCore);
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints stAztec shares to an account.
    /// @param to The recipient address.
    /// @param amount The amount of shares to mint.
    function mint(address to, uint256 amount) external override onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burns stAztec shares from an account.
    /// @param from The account to burn shares from.
    /// @param amount The amount of shares to burn.
    function burn(address from, uint256 amount) external override onlyRole(BURNER_ROLE) {
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
