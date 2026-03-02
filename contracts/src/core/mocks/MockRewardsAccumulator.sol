// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";

import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { IMockRewardsAccumulator } from "src/core/mocks/IMockRewardsAccumulator.sol";

/// @title MockRewardsAccumulator
/// @notice Mock rewards vault for testing StakingManager reward harvesting.
/// @dev Implements IRewardsAccumulator interface with test helpers.
/// @author Olla Core contributors
contract MockRewardsAccumulator is IMockRewardsAccumulator {
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

    /// @notice Constructs the MockRewardsAccumulator.
    /// @param rewardsToken_ The rewards token address.
    /// @param coreAddress The core contract address.
    constructor(IERC20 rewardsToken_, address coreAddress) {
        REWARDS_TOKEN = rewardsToken_;
        CORE_ADDRESS = coreAddress;
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsAccumulator
    function recordBalance() external override returns (uint256 balanceDelta) {
        if (_hookShouldFail) {
            revert MockRewardsAccumulator__HookFailed();
        }
        uint256 currentBalance = REWARDS_TOKEN.balanceOf(address(this));
        balanceDelta = currentBalance - _latestRecordedRewardsAmount;
        _totalReceived += balanceDelta;
        _latestRecordedRewardsAmount = currentBalance;
        emit RewardsRecorded(balanceDelta);
        return balanceDelta;
    }

    /// @inheritdoc IRewardsAccumulator
    function withdrawToCore() external override {
        uint256 available = REWARDS_TOKEN.balanceOf(address(this));
        _latestRecordedRewardsAmount = 0;
        REWARDS_TOKEN.safeTransfer(CORE_ADDRESS, available);
        emit RewardsWithdrawn(available);
    }

    /*//////////////////////////////////////////////////////////////
                          TEST HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockRewardsAccumulator
    function setHookShouldFail(bool shouldFail) external override {
        _hookShouldFail = shouldFail;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsAccumulator
    function balance() external view override returns (uint256) {
        return REWARDS_TOKEN.balanceOf(address(this));
    }

    /// @inheritdoc IRewardsAccumulator
    function core() external view override returns (address) {
        return CORE_ADDRESS;
    }

    /// @inheritdoc IRewardsAccumulator
    function rewardsToken() external view override returns (IERC20) {
        return REWARDS_TOKEN;
    }

    /// @inheritdoc IMockRewardsAccumulator
    function totalReceived() external view override returns (uint256) {
        return _totalReceived;
    }

    /// @inheritdoc IRewardsAccumulator
    function latestRecordedRewardsAmount() external view override returns (uint256) {
        return _latestRecordedRewardsAmount;
    }

    /// @inheritdoc IRewardsAccumulator
    function initialize(IERC20, address, address) external pure override {
        revert MockRewardsAccumulator__NoInitializer();
    }
}
