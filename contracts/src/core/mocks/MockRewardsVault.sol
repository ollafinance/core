// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { IMockRewardsVault } from "src/core/mocks/IMockRewardsVault.sol";

/// @title MockRewardsVault
/// @notice Mock rewards vault for testing StakingManager reward harvesting.
/// @dev Implements IRewardsVault interface with test helpers.
/// @author Olla Core contributors
contract MockRewardsVault is IMockRewardsVault {
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

    /// @notice Treasury address.
    address private _treasury;

    /// @notice Total funds received via postReceiveFundsHook.
    uint256 private _totalReceived;

    /// @notice Whether postReceiveFundsHook should fail.
    bool private _hookShouldFail;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the MockRewardsVault.
    /// @param rewardsToken_ The rewards token address.
    /// @param coreAddress The core contract address.
    /// @param treasuryAddress The treasury address.
    constructor(IERC20 rewardsToken_, address coreAddress, address treasuryAddress) {
        REWARDS_TOKEN = rewardsToken_;
        CORE_ADDRESS = coreAddress;
        _treasury = treasuryAddress;
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsVault
    function postReceiveFundsHook(uint256 amount) external override {
        if (_hookShouldFail) {
            revert MockRewardsVault__HookFailed();
        }
        _totalReceived += amount;
        emit RewardsRecorded(amount);
    }

    /// @inheritdoc IRewardsVault
    function withdrawToCore() external override {
        uint256 available = REWARDS_TOKEN.balanceOf(address(this));
        REWARDS_TOKEN.transfer(CORE_ADDRESS, available);
        emit RewardsWithdrawn(available);
    }

    /// @inheritdoc IRewardsVault
    function setTreasury(address newTreasury) external override {
        if (newTreasury == address(0)) {
            revert RewardsVault__ZeroAddress("treasury");
        }
        address oldTreasury = _treasury;
        _treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
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
    function treasury() external view override returns (address) {
        return _treasury;
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
}
