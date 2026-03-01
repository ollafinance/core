// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { OwnableUpgradeable } from "@oz-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IRewardsCollector } from "src/core/interfaces/IRewardsCollector.sol";

/// @title RewardsCollector
/// @notice Base implementation for rewards and fee management vault.
/// @author Olla Core contributors
contract RewardsCollector is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuard, IRewardsCollector {
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
    /// @dev State variables occupy 3 slots. When adding new state variables, append them above
    ///      this gap and reduce its length by the number of slots consumed.
    // slither-disable-next-line unused-state
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error RewardsCollector__UnauthorizedGovernance(address caller);

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCore() {
        if (msg.sender != core) {
            revert IRewardsCollector.RewardsCollector__UnauthorizedCore(msg.sender);
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

    /// @notice Initializes the RewardsCollector behind a proxy.
    /// @param rewardsToken_ The rewards token address.
    /// @param core_ The core contract address.
    /// @param defaultAdmin_ The default admin for role management.
    function initialize(IERC20 rewardsToken_, address core_, address defaultAdmin_) external override initializer {
        if (address(rewardsToken_) == address(0)) {
            revert RewardsCollector__ZeroAddress("rewardsToken");
        }
        if (core_ == address(0)) {
            revert RewardsCollector__ZeroAddress("core");
        }
        if (defaultAdmin_ == address(0)) {
            revert RewardsCollector__ZeroAddress("defaultAdmin");
        }

        __AccessControl_init();

        rewardsToken = rewardsToken_;
        core = core_;

        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, defaultAdmin_);
    }

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsCollector
    function recordBalance() external override onlyCore nonReentrant returns (uint256 balanceDelta) {
        uint256 previousAmount = latestRecordedRewardsAmount;
        uint256 currentTokenBalance = rewardsToken.balanceOf(address(this));
        // Revert if balance decreased (should never happen in normal operation)
        if (currentTokenBalance < previousAmount) {
            revert RewardsCollector__BalanceMismatch();
        }
        balanceDelta = currentTokenBalance - previousAmount;
        latestRecordedRewardsAmount = currentTokenBalance;
        emit RewardsRecorded(balanceDelta);
        return balanceDelta;
    }

    /// @inheritdoc IRewardsCollector
    function withdrawToCore() external override onlyCore nonReentrant {
        uint256 availableBalance = rewardsToken.balanceOf(address(this));
        // slither-disable-next-line incorrect-equality
        if (availableBalance == 0) {
            revert RewardsCollector__ZeroAmount();
        }
        // slither-disable-next-line incorrect-equality
        if (availableBalance != latestRecordedRewardsAmount) {
            // NOTE: this practically forces to run recordBalance in same tx before withdrawing
            revert RewardsCollector__BalanceMismatch();
        }
        rewardsToken.safeTransfer(core, availableBalance);
        latestRecordedRewardsAmount = 0;
        emit RewardsWithdrawn(availableBalance);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsCollector
    function balance() external view override returns (uint256) {
        return rewardsToken.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                             UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorizes upgrade to new implementation.
    /// @param newImplementation The new implementation address.
    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != OwnableUpgradeable(core).owner()) {
            revert RewardsCollector__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert RewardsCollector__ZeroAddress("newImplementation");
        }
    }
}
