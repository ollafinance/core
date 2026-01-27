// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";

/// @title RewardsVault
/// @notice Base implementation for rewards and fee management vault.
/// @author Olla Core contributors
contract RewardsVault is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuard, IRewardsVault {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                  CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for core contract to call vault functions.
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    /*//////////////////////////////////////////////////////////////
                                    STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The rewards token (same as staking asset).
    IERC20 public immutable REWARDS_TOKEN;

    /// @notice The core contract address.
    address public core;

    /// @notice The latest recorded rewards amount.
    uint256 public latestRecordedRewardsAmount;

    /// @notice The cumulative rewards amount withdrawn.
    uint256 public cumulativeRewardsWithdrawn;

    /// @notice Storage gap for future upgrades.
    // slither-disable-next-line unused-state
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the RewardsVault behind a proxy.
    /// @param rewardsToken_ The rewards token address.
    /// @param core_ The core contract address.
    /// @param defaultAdmin_ The default admin for role management.
    function initialize(IERC20 rewardsToken_, address core_, address defaultAdmin_) external override initializer {
        if (address(rewardsToken_) == address(0)) {
            revert RewardsVault__ZeroAddress("rewardsToken");
        }
        if (core_ == address(0)) {
            revert RewardsVault__ZeroAddress("core");
        }
        if (defaultAdmin_ == address(0)) {
            revert RewardsVault__ZeroAddress("defaultAdmin");
        }

        __AccessControl_init();

        REWARDS_TOKEN = rewardsToken_;
        core = core_;

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin_);
        _grantRole(CORE_ROLE, core_);
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // TODO: rename this hook to "recordRewards" or similar
    /// @inheritdoc IRewardsVault
    function postReceiveFundsHook(uint256 amount) external override onlyRole(CORE_ROLE) nonReentrant {
        if (amount == 0) revert RewardsVault__ZeroAmount();

        uint256 previousAmount = latestRecordedRewardsAmount;
        uint256 harvestedRewards = amount;
        uint256 currentTokenBalance = REWARDS_TOKEN.balanceOf(address(this));
        uint256 excessFundsAmount = currentTokenBalance - previousAmount - harvestedRewards;
        if (excessFundsAmount > 0) {
            emit ExcessFundsDetected(excessFundsAmount);
        }
        // Total rewards is harvested rewards plus any excess funds detected
        uint256 rewardsIsh = harvestedRewards + excessFundsAmount;
        if (currentTokenBalance != previousAmount + rewardsIsh) {
            revert RewardsVault__BalanceMismatch();
        }
        latestRecordedRewardsAmount = currentTokenBalance;
        emit RewardsRecorded(rewardsIsh);
    }

    /// @inheritdoc IRewardsVault
    function withdrawToCore() external override onlyRole(CORE_ROLE) nonReentrant {
        uint256 availableBalance = REWARDS_TOKEN.balanceOf(address(this));
        if (availableBalance == 0) revert RewardsVault__ZeroAmount();
        REWARDS_TOKEN.safeTransfer(core, availableBalance);
        cumulativeRewardsWithdrawn += availableBalance;
        emit RewardsWithdrawn(availableBalance);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsVault
    function balance() external view override returns (uint256) {
        return REWARDS_TOKEN.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorizes upgrade to new implementation.
    /// @param newImplementation The new implementation address.
    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImplementation == address(0)) {
            revert RewardsVault__ZeroAddress("newImplementation");
        }
    }
}
