// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC20} from "dependencies/@openzeppelin-contracts-5.5.0-rc.1/token/ERC20/ERC20.sol";
import {ERC20Permit} from "dependencies/@openzeppelin-contracts-5.5.0-rc.1/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Metadata} from "dependencies/@openzeppelin-contracts-5.5.0-rc.1/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "dependencies/@openzeppelin-contracts-5.5.0-rc.1/token/ERC20/extensions/IERC20Permit.sol";

import {IStAztec} from "src/interfaces/IStAztec.sol";

/// @title StAztec
/// @notice ERC-20 token representing staked Aztec shares in OllaCore.
/// @author Olla Core contributors
contract StAztec is ERC20Permit, IStAztec {
    uint8 private constant _DECIMALS = 18;

    /// @notice OllaCore contract allowed to mint and burn.
    address public immutable OLLA_CORE;

    /// @notice Thrown when a caller is not authorized to mint/burn.
    error StAztecUnauthorized(address caller);

    /// @notice Thrown when a zero address is provided.
    error StAztecZeroAddress();

    /// @notice Sets the OllaCore address and token metadata.
    /// @param ollaCore Address of OllaCore authorized to mint/burn.
    constructor(
        address ollaCore
    ) ERC20("stAztec", "stAZTEC") ERC20Permit("stAztec") {
        if (ollaCore == address(0)) {
            revert StAztecZeroAddress();
        }

        OLLA_CORE = ollaCore;
    }

    /// @notice Mints stAztec shares to an account.
    /// @param to The recipient address.
    /// @param amount The amount of shares to mint.
    function mint(address to, uint256 amount) external override {
        _requireAuthorized();
        _mint(to, amount);
    }

    /// @notice Burns stAztec shares from an account.
    /// @param from The account to burn shares from.
    /// @param amount The amount of shares to burn.
    function burn(address from, uint256 amount) external override {
        _requireAuthorized();
        _burn(from, amount);
    }

    /// @notice Returns the current permit nonce for an owner.
    /// @param owner The address to query.
    /// @return The current permit nonce.
    function nonces(
        address owner
    ) public view override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    /// @notice Returns the decimals used by the token.
    /// @return The number of decimals for the token.
    function decimals()
        public
        pure
        override(ERC20, IERC20Metadata)
        returns (uint8)
    {
        return _DECIMALS;
    }

    function _requireAuthorized() internal view {
        if (msg.sender != OLLA_CORE) {
            revert StAztecUnauthorized(msg.sender);
        }
    }
}
