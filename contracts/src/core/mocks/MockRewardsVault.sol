// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";

import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { IMockRewardsVault } from "src/core/mocks/IMockRewardsVault.sol";

/// @title MockRewardsVault
/// @notice Mock rewards vault for testing StakingManager reward harvesting.
/// @dev Implements IRewardsVault interface with test helpers.
/// @author Olla Core contributors
contract MockRewardsVault is IMockRewardsVault {
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

    /// @notice Constructs the MockRewardsVault.
    /// @param rewardsToken_ The rewards token address.
    /// @param coreAddress The core contract address.
    constructor(IERC20 rewardsToken_, address coreAddress) {
        REWARDS_TOKEN = rewardsToken_;
        CORE_ADDRESS = coreAddress;
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsVault
    function recordBalance() external override returns (uint256 balanceDelta) {
        if (_hookShouldFail) {
            revert MockRewardsVault__HookFailed();
        }
        uint256 currentBalance = REWARDS_TOKEN.balanceOf(address(this));
        balanceDelta = currentBalance - _latestRecordedRewardsAmount;
        _totalReceived += balanceDelta;
        _latestRecordedRewardsAmount = currentBalance;
        emit RewardsRecorded(balanceDelta);
        return balanceDelta;
    }

    /// @inheritdoc IRewardsVault
    function withdrawToCore() external override {
        uint256 available = REWARDS_TOKEN.balanceOf(address(this));
        _latestRecordedRewardsAmount = 0;
        REWARDS_TOKEN.safeTransfer(CORE_ADDRESS, available);
        emit RewardsWithdrawn(available);
    }

    /*//////////////////////////////////////////////////////////////
                          TEST HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockRewardsVault
    function setHookShouldFail(bool shouldFail) external override {
        _hookShouldFail = shouldFail;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsVault
    function balance() external view override returns (uint256) {
        return REWARDS_TOKEN.balanceOf(address(this));
    }

    /// @inheritdoc IRewardsVault
    function core() external view override returns (address) {
        return CORE_ADDRESS;
    }

    /// @inheritdoc IRewardsVault
    function rewardsToken() external view override returns (IERC20) {
        return REWARDS_TOKEN;
    }

    /// @inheritdoc IMockRewardsVault
    function totalReceived() external view override returns (uint256) {
        return _totalReceived;
    }

    /// @inheritdoc IRewardsVault
    function latestRecordedRewardsAmount() external view override returns (uint256) {
        return _latestRecordedRewardsAmount;
    }

    /// @inheritdoc IRewardsVault
    function initialize(IERC20, address, address) external pure override {
        revert MockRewardsVault__NoInitializer();
    }
}
