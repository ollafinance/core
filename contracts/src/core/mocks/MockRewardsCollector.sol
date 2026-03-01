// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";

import { IRewardsCollector } from "src/core/interfaces/IRewardsCollector.sol";
import { IMockRewardsCollector } from "src/core/mocks/IMockRewardsCollector.sol";

/// @title MockRewardsCollector
/// @notice Mock rewards vault for testing StakingManager reward harvesting.
/// @dev Implements IRewardsCollector interface with test helpers.
/// @author Olla Core contributors
contract MockRewardsCollector is IMockRewardsCollector {
    using SafeERC20 for IERC20;
    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The rewards token (AZTEC).
    IERC20 public immutable REWARDS_TOKEN;

    /// @notice The core contract address.
    address public immutable CORE_ADDRESS;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Total funds received via recordBalance.
    uint256 private _totalReceived;

    /// @notice Latest recorded rewards amount (for interface compliance).
    uint256 private _latestRecordedRewardsAmount;

    /// @notice Whether recordBalance should fail.
    bool private _hookShouldFail;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the MockRewardsCollector.
    /// @param rewardsToken_ The rewards token address.
    /// @param coreAddress The core contract address.
    constructor(IERC20 rewardsToken_, address coreAddress) {
        REWARDS_TOKEN = rewardsToken_;
        CORE_ADDRESS = coreAddress;
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsCollector
    function recordBalance() external override returns (uint256 balanceDelta) {
        if (_hookShouldFail) {
            revert MockRewardsCollector__HookFailed();
        }
        uint256 currentBalance = REWARDS_TOKEN.balanceOf(address(this));
        balanceDelta = currentBalance - _latestRecordedRewardsAmount;
        _totalReceived += balanceDelta;
        _latestRecordedRewardsAmount = currentBalance;
        emit RewardsRecorded(balanceDelta);
        return balanceDelta;
    }

    /// @inheritdoc IRewardsCollector
    function withdrawToCore() external override {
        uint256 available = REWARDS_TOKEN.balanceOf(address(this));
        _latestRecordedRewardsAmount = 0;
        REWARDS_TOKEN.safeTransfer(CORE_ADDRESS, available);
        emit RewardsWithdrawn(available);
    }

    /*//////////////////////////////////////////////////////////////
                          TEST HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockRewardsCollector
    function setHookShouldFail(bool shouldFail) external override {
        _hookShouldFail = shouldFail;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsCollector
    function balance() external view override returns (uint256) {
        return REWARDS_TOKEN.balanceOf(address(this));
    }

    /// @inheritdoc IRewardsCollector
    function core() external view override returns (address) {
        return CORE_ADDRESS;
    }

    /// @inheritdoc IRewardsCollector
    function rewardsToken() external view override returns (IERC20) {
        return REWARDS_TOKEN;
    }

    /// @inheritdoc IMockRewardsCollector
    function totalReceived() external view override returns (uint256) {
        return _totalReceived;
    }

    /// @inheritdoc IRewardsCollector
    function latestRecordedRewardsAmount() external view override returns (uint256) {
        return _latestRecordedRewardsAmount;
    }

    /// @inheritdoc IRewardsCollector
    function initialize(IERC20, address, address) external pure override {
        revert MockRewardsCollector__NoInitializer();
    }
}
