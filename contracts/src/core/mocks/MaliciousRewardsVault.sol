// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Address } from "@oz/utils/Address.sol";
import { IMaliciousRewardsVault } from "src/core/mocks/IMaliciousRewardsVault.sol";

/// @title MaliciousRewardsVault
/// @notice Test-only rewards vault that attempts reentrancy in postReceiveFundsHook.
/// @author Olla Core contributors
contract MaliciousRewardsVault is IMaliciousRewardsVault {
    using Address for address;

    /// @notice The rewards token (AZTEC).
    IERC20 public immutable REWARDS_TOKEN;

    /// @notice The core contract address.
    address public immutable CORE_ADDRESS;

    address private _treasury;
    uint256 private _totalReceived;

    address private _reentryTarget;
    bytes private _reentryCalldata;
    bool private _reenterOnHook;

    constructor(IERC20 rewardsToken_, address coreAddress_, address treasuryAddress_) {
        REWARDS_TOKEN = rewardsToken_;
        CORE_ADDRESS = coreAddress_;
        _treasury = treasuryAddress_;
    }

    /// @notice Configure the call attempted from `postReceiveFundsHook`.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @param enabled Whether to enable the reentrancy attempt.
    function configureReentry(address target, bytes calldata data, bool enabled) external override {
        _reentryTarget = target;
        _reentryCalldata = data;
        _reenterOnHook = enabled;
    }

    /// @notice Hook called after receiving rewards.
    /// @param amount The amount received.
    function postReceiveFundsHook(uint256 amount) external override {
        if (_reenterOnHook) {
            _reenterOnHook = false;
            _reentryTarget.functionCall(_reentryCalldata);
        }
        _totalReceived += amount;
        emit FundsReceived(amount);
    }

    /// @notice Withdraw rewards to core.
    /// @param amount The amount to withdraw.
    function withdrawToCore(uint256 amount) external override {
        uint256 available = REWARDS_TOKEN.balanceOf(address(this));
        if (amount > available) {
            revert RewardsVault__InsufficientBalance(amount, available);
        }
        REWARDS_TOKEN.transfer(CORE_ADDRESS, amount);
        emit RewardsWithdrawn(amount);
    }

    /// @notice Set the treasury address.
    /// @param newTreasury The new treasury.
    function setTreasury(address newTreasury) external override {
        if (newTreasury == address(0)) {
            revert RewardsVault__ZeroAddress("treasury");
        }
        address oldTreasury = _treasury;
        _treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /// @notice Return the available rewards token balance.
    /// @return The available balance.
    function getAvailableFunds() external view override returns (uint256) {
        return REWARDS_TOKEN.balanceOf(address(this));
    }

    /// @notice Return the treasury address.
    /// @return The treasury address.
    function treasury() external view override returns (address) {
        return _treasury;
    }

    /// @notice Return the core address.
    /// @return The core address.
    function core() external view override returns (address) {
        return CORE_ADDRESS;
    }

    /// @notice Return the rewards token.
    /// @return The rewards token.
    function rewardsToken() external view override returns (IERC20) {
        return REWARDS_TOKEN;
    }

    /// @notice Return the total amount passed to `postReceiveFundsHook`.
    /// @return The total received.
    function totalReceived() external view override returns (uint256) {
        return _totalReceived;
    }
}
