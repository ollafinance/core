// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Address } from "@oz/utils/Address.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { IMaliciousRewardsVault } from "src/core/mocks/IMaliciousRewardsVault.sol";

/// @title MaliciousRewardsVault
/// @notice Test-only rewards vault that attempts reentrancy in recordRewards.
/// @author Olla Core contributors
contract MaliciousRewardsVault is IMaliciousRewardsVault {
    using Address for address;

    /// @notice The rewards token (AZTEC).
    IERC20 public immutable REWARDS_TOKEN;

    /// @notice The core contract address.
    address public immutable CORE_ADDRESS;

    uint256 private _totalReceived;
    uint256 private _latestRecordedRewardsAmount;

    address private _reentryTarget;
    bytes private _reentryCalldata;
    bool private _reenterOnHook;

    constructor(IERC20 rewardsToken_, address coreAddress_) {
        REWARDS_TOKEN = rewardsToken_;
        CORE_ADDRESS = coreAddress_;
    }

    /// @notice Configure the call attempted from `recordRewards`.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @param enabled Whether to enable the reentrancy attempt.
    function configureReentry(address target, bytes calldata data, bool enabled) external override {
        _reentryTarget = target;
        _reentryCalldata = data;
        _reenterOnHook = enabled;
    }

    /// @notice Hook called after receiving rewards.
    /// @param expectedRewards The amount of rewards transferred.
    function recordRewards(uint256 expectedRewards) external override {
        if (_reenterOnHook) {
            _reenterOnHook = false;
            _reentryTarget.functionCall(_reentryCalldata);
        }
        _totalReceived += expectedRewards;
        _latestRecordedRewardsAmount = REWARDS_TOKEN.balanceOf(address(this));
        emit RewardsRecorded(expectedRewards);
    }

    /// @notice Withdraw rewards to core.
    function withdrawToCore() external override {
        uint256 available = REWARDS_TOKEN.balanceOf(address(this));
        _latestRecordedRewardsAmount = 0;
        REWARDS_TOKEN.transfer(CORE_ADDRESS, available);
        emit RewardsWithdrawn(available);
    }

    /// @notice Return the available rewards token balance.
    /// @return The available balance.
    function balance() external view override returns (uint256) {
        return REWARDS_TOKEN.balanceOf(address(this));
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

    /// @notice Return the total amount passed to `recordRewards`.
    /// @return The total received.
    function totalReceived() external view override returns (uint256) {
        return _totalReceived;
    }

    /// @inheritdoc IRewardsVault
    function latestRecordedRewardsAmount() external view override returns (uint256) {
        return _latestRecordedRewardsAmount;
    }

    /// @inheritdoc IRewardsVault
    function initialize(IERC20, address, address) external pure override {
        revert MaliciousRewardsVault__NoInitializer();
    }
}
