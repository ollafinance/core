// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { ERC20 } from "@oz/token/ERC20/ERC20.sol";
import { Address } from "@oz/utils/Address.sol";

import { IERC20Mintable } from "src/interfaces/IERC20Mintable.sol";
import { IMaliciousAztec } from "src/staking/mocks/IMaliciousAztec.sol";

/// @title MaliciousAztec
/// @notice Test-only ERC20 that attempts reentrancy during transfer or transferFrom.
/// @author Olla Core contributors
contract MaliciousAztec is IMaliciousAztec, IERC20Mintable, ERC20 {
    using Address for address;

    address private _reentryTarget;
    bytes private _reentryCalldata;
    bool private _reenterOnTransferFrom;

    address private _transferReentryTarget;
    bytes private _transferReentryCalldata;
    bool private _reenterOnTransfer;
    uint256 private _transferReentrySkipCount;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() ERC20("AZTEC", "AZTEC") { }

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure a reentrancy attempt during transferFrom.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @param enabled Whether to enable the reentrancy attempt.
    function configureReentry(address target, bytes calldata data, bool enabled) external override {
        _reentryTarget = target;
        _reentryCalldata = data;
        _reenterOnTransferFrom = enabled;
    }

    /// @notice Set the number of transfer calls to skip before triggering re-entry.
    /// @param count The number of transfers to skip (0 = fire on first transfer).
    function setTransferReentrySkipCount(uint256 count) external override {
        _transferReentrySkipCount = count;
    }

    /// @notice Configure a reentrancy attempt during transfer.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @param enabled Whether to enable the reentrancy attempt.
    function configureTransferReentry(address target, bytes calldata data, bool enabled) external override {
        _transferReentryTarget = target;
        _transferReentryCalldata = data;
        _reenterOnTransfer = enabled;
    }

    /// @notice Set allowance from this token contract to itself.
    /// @param amount The allowance amount.
    function setSelfAllowance(uint256 amount) external override {
        _approve(address(this), address(this), amount);
    }

    /// @notice Mints tokens to the recipient.
    /// @param to The recipient address.
    /// @param amount The token amount to mint.
    function mint(address to, uint256 amount) external override {
        _mint(to, amount);
    }

    /// @inheritdoc ERC20
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (_reenterOnTransfer) {
            if (_transferReentrySkipCount == 0) {
                _reenterOnTransfer = false;
                _transferReentryTarget.functionCall(_transferReentryCalldata);
            } else {
                --_transferReentrySkipCount;
            }
        }
        return super.transfer(to, amount);
    }

    /// @inheritdoc ERC20
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (_reenterOnTransferFrom) {
            _reenterOnTransferFrom = false;
            _reentryTarget.functionCall(_reentryCalldata);
        }
        return super.transferFrom(from, to, amount);
    }
}
