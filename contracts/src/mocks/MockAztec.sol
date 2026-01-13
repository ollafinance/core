// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Ownable2Step, Ownable } from "@oz/access/Ownable2Step.sol";
import { ERC20 } from "@oz/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@oz/token/ERC20/extensions/ERC20Permit.sol";

import { IERC20Mintable } from "src/interfaces/IERC20Mintable.sol";

/// @title MockAztec
/// @notice Mock Aztec asset for tests.
/// @author Olla Core contributors
contract MockAztec is IERC20Mintable, ERC20, Ownable2Step, ERC20Permit {
    constructor(address initialOwner) ERC20("AZTEC", "AZTEC") Ownable(initialOwner) ERC20Permit("AZTEC") { }

    /// @notice Mints tokens to the recipient.
    /// @param to The recipient address.
    /// @param amount The token amount to mint.
    function mint(address to, uint256 amount) external override onlyOwner {
        _mint(to, amount);
    }
}
