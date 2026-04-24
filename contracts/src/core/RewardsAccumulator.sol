// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@oz/utils/ReentrancyGuardTransient.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";

/// @title RewardsAccumulator
/// @notice Base implementation for rewards and fee management vault.
/// @author Olla Core contributors
contract RewardsAccumulator is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    IRewardsAccumulator
{
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

    /// @notice Governance contract authorized to perform UUPS upgrades.
    address public governanceUpgradeAuthority;

    /// @notice Storage gap for future upgrades.
    /// @dev When adding new state variables, append them above this gap and reduce its length
    ///      by the number of slots consumed. Target: 50 gap slots across all upgradeable contracts.
    // slither-disable-next-line unused-state
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error RewardsAccumulator__UnauthorizedGovernance(address caller);

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCore() {
        if (msg.sender != core) {
            revert IRewardsAccumulator.RewardsAccumulator__UnauthorizedCore(msg.sender);
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

    /// @notice Initializes the RewardsAccumulator behind a proxy.
    /// @param rewardsToken_ The rewards token address.
    /// @param core_ The core contract address.
    /// @param defaultAdmin_ The default admin for role management.
    function initialize(IERC20 rewardsToken_, address core_, address defaultAdmin_) external override initializer {
        if (address(rewardsToken_) == address(0)) {
            revert RewardsAccumulator__ZeroAddress("rewardsToken");
        }
        if (core_ == address(0)) {
            revert RewardsAccumulator__ZeroAddress("core");
        }
        if (defaultAdmin_ == address(0)) {
            revert RewardsAccumulator__ZeroAddress("defaultAdmin");
        }

        __AccessControl_init();
        __ReentrancyGuard_init();

        rewardsToken = rewardsToken_;
        core = core_;
        governanceUpgradeAuthority = defaultAdmin_;

        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, defaultAdmin_);
    }

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsAccumulator
    /// @dev Balance-based delta intentionally includes unsolicited transfers. Fee extraction on
    ///      donated funds is accepted as economically self-defeating for the donor - the attacker
    ///      loses the full donation while the protocol mints fee shares worth at most half the
    ///      donated amount. This is a known characteristic of balance-based reward accumulators.
    function recordBalance() external override onlyCore nonReentrant returns (uint256 balanceDelta) {
        uint256 previousAmount = latestRecordedRewardsAmount;
        uint256 currentTokenBalance = rewardsToken.balanceOf(address(this));
        // Revert if balance decreased (should never happen in normal operation)
        if (currentTokenBalance < previousAmount) {
            revert RewardsAccumulator__BalanceMismatch();
        }
        balanceDelta = currentTokenBalance - previousAmount;
        latestRecordedRewardsAmount = currentTokenBalance;
        emit RewardsRecorded(balanceDelta);
        return balanceDelta;
    }

    /// @inheritdoc IRewardsAccumulator
    function withdrawToCore() external override onlyCore nonReentrant {
        uint256 availableBalance = rewardsToken.balanceOf(address(this));
        // Zero-balance guard; must have funds to withdraw.
        // slither-disable-next-line incorrect-equality
        if (availableBalance == 0) {
            revert RewardsAccumulator__ZeroAmount();
        }
        // Staleness guard: forces recordBalance() in the same tx before withdrawal.
        // slither-disable-next-line incorrect-equality
        if (availableBalance != latestRecordedRewardsAmount) {
            // NOTE: this practically forces to run recordBalance in same tx before withdrawing
            revert RewardsAccumulator__BalanceMismatch();
        }
        rewardsToken.safeTransfer(core, availableBalance);
        latestRecordedRewardsAmount = 0;
        emit RewardsWithdrawn(availableBalance);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsAccumulator
    function balance() external view override returns (uint256) {
        return rewardsToken.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                             UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorizes upgrade to new implementation.
    /// @param newImplementation The new implementation address.
    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != governanceUpgradeAuthority) {
            revert RewardsAccumulator__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert RewardsAccumulator__ZeroAddress("newImplementation");
        }
    }
}
