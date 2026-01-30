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
                                       STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The rewards token (same as staking asset).
    IERC20 public rewardsToken;

    /// @notice The core contract address.
    address public core;

    /// @notice The latest recorded rewards amount.
    uint256 public latestRecordedRewardsAmount;

    /// @notice Storage gap for future upgrades.
    // slither-disable-next-line unused-state
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCore() {
        if (msg.sender != core) {
            revert RewardsVault__UnauthorizedCore(msg.sender);
        }
        _;
    }

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

        rewardsToken = rewardsToken_;
        core = core_;

        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, defaultAdmin_);
    }

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsVault
    function recordRewards(uint256 expectedRewards) external override onlyCore nonReentrant {
        // TODO: refactor this function to only update latestRecordedRewardsAmount and return the delta
        //       1. ExcessFundsDetected should be removed entirely from this class/interface (there is no excess, all delta are rewards)
        //       2. RewardsRecorded should emit only the delta (current - previous)
        //       3. It should not take a param, and it should therefore not revert either
        if (expectedRewards == 0) revert RewardsVault__ZeroAmount();

        uint256 previousAmount = latestRecordedRewardsAmount;
        uint256 currentTokenBalance = rewardsToken.balanceOf(address(this));
        uint256 excessFundsAmount = currentTokenBalance - previousAmount - expectedRewards;
        if (excessFundsAmount > 0) {
            emit ExcessFundsDetected(excessFundsAmount);
        }
        // Total rewards is harvested rewards plus any excess funds detected
        uint256 rewardsIsh = expectedRewards + excessFundsAmount;
        if (currentTokenBalance != previousAmount + rewardsIsh) {
            revert RewardsVault__BalanceMismatch();
        }
        latestRecordedRewardsAmount = currentTokenBalance;
        emit RewardsRecorded(rewardsIsh);
    }

    /// @inheritdoc IRewardsVault
    function withdrawToCore() external override onlyCore nonReentrant {
        uint256 availableBalance = rewardsToken.balanceOf(address(this));
        // slither-disable-next-line incorrect-equality
        if (availableBalance == 0) {
            revert RewardsVault__ZeroAmount();
        }
        // slither-disable-next-line incorrect-equality
        if (availableBalance != latestRecordedRewardsAmount) {
            // NOTE: this practically forces to run recordRewards in same tx before withdrawing
            revert RewardsVault__BalanceMismatch();
        }
        rewardsToken.safeTransfer(core, availableBalance);
        latestRecordedRewardsAmount = 0;
        emit RewardsWithdrawn(availableBalance);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsVault
    function balance() external view override returns (uint256) {
        return rewardsToken.balanceOf(address(this));
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
