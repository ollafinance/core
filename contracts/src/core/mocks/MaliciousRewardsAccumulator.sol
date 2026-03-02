// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@oz/utils/Address.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { IMaliciousRewardsAccumulator } from "src/core/mocks/IMaliciousRewardsAccumulator.sol";

/// @title MaliciousRewardsAccumulator
/// @notice Test-only rewards vault that attempts reentrancy in recordBalance.
/// @author Olla Core contributors
contract MaliciousRewardsAccumulator is IMaliciousRewardsAccumulator {
    using Address for address;
    using SafeERC20 for IERC20;

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

    /// @notice Configure the call attempted from `recordBalance`.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @param enabled Whether to enable the reentrancy attempt.
    function configureReentry(address target, bytes calldata data, bool enabled) external override {
        _reentryTarget = target;
        _reentryCalldata = data;
        _reenterOnHook = enabled;
    }

    /// @inheritdoc IRewardsAccumulator
    function recordBalance() external override returns (uint256 balanceDelta) {
        if (_reenterOnHook) {
            _reenterOnHook = false;
            _reentryTarget.functionCall(_reentryCalldata);
        }
        uint256 currentBalance = REWARDS_TOKEN.balanceOf(address(this));
        balanceDelta = currentBalance - _latestRecordedRewardsAmount;
        _totalReceived += balanceDelta;
        _latestRecordedRewardsAmount = currentBalance;
        emit RewardsRecorded(balanceDelta);
        return balanceDelta;
    }

    /// @notice Withdraw rewards to core.
    function withdrawToCore() external override {
        uint256 available = REWARDS_TOKEN.balanceOf(address(this));
        _latestRecordedRewardsAmount = 0;
        REWARDS_TOKEN.safeTransfer(CORE_ADDRESS, available);
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

    /// @notice Return the total amount passed to `recordBalance`.
    /// @return The total received.
    function totalReceived() external view override returns (uint256) {
        return _totalReceived;
    }

    /// @inheritdoc IRewardsAccumulator
    function latestRecordedRewardsAmount() external view override returns (uint256) {
        return _latestRecordedRewardsAmount;
    }

    /// @inheritdoc IRewardsAccumulator
    function initialize(IERC20, address, address) external pure override {
        revert MaliciousRewardsAccumulator__NoInitializer();
    }
}
