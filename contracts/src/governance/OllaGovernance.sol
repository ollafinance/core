// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { TimelockControllerUpgradeable } from "@oz-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaGovernance
/// @notice Governance contract for the Olla protocol. Inherits TimelockController for
///         time-delayed execution of governance actions, and is UUPS-upgradeable.
///         All parameter changes and upgrades flow through the timelock (schedule -> execute).
/// @author Olla Core contributors
contract OllaGovernance is Initializable, TimelockControllerUpgradeable, UUPSUpgradeable, IOllaGovernance {
    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The OllaCore contract this governance manages.
    address public override core;

    /// @notice The treasury address where fees are sent.
    address public override treasury;

    /// @notice Pending governance address for two-step governance transfer.
    address public override pendingGovernance;

    /// @notice The current governance admin (holds proposer/executor/canceller roles).
    /// @dev Tracked explicitly because AccessControl doesn't support role enumeration.
    address public governanceAdmin;

    /// @notice Storage gap for future upgrades.
    // slither-disable-next-line unused-state
    uint256[46] private __gap;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts to calls from address(this), i.e. through the timelock execute flow.
    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert OllaGovernance__OnlySelf();
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

    /// @inheritdoc IOllaGovernance
    function initialize(
        uint256 minDelay,
        address[] calldata proposers,
        address[] calldata executors,
        address admin,
        address treasury_
    ) external override initializer {
        if (admin == address(0)) {
            revert OllaGovernance__ZeroAddress("admin");
        }
        if (treasury_ == address(0)) {
            revert OllaGovernance__ZeroAddress("treasury");
        }

        __TimelockController_init(minDelay, proposers, executors, admin);

        treasury = treasury_;
        // The first proposer is the initial governance admin
        if (proposers.length > 0) {
            governanceAdmin = proposers[0];
        }
    }

    /*//////////////////////////////////////////////////////////////
                          SETUP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time setter for the OllaCore contract reference.
    /// @dev Called after OllaCore is deployed and initialized. Can only be called once.
    ///      Must be called by an address holding DEFAULT_ADMIN_ROLE.
    /// @param core_ The OllaCore contract address.
    function setCore(address core_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (core_ == address(0)) {
            revert OllaGovernance__ZeroAddress("core");
        }
        if (core != address(0)) {
            revert OllaGovernance__CoreAlreadySet();
        }
        core = core_;
        emit CoreSet(core_);
    }

    /*//////////////////////////////////////////////////////////////
                         GOVERNANCE TRANSFER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaGovernance
    function proposeGovernance(address newGovernance) external override onlySelf {
        if (newGovernance == address(0)) {
            revert OllaGovernance__ZeroAddress("newGovernance");
        }
        if (pendingGovernance != address(0)) {
            revert OllaGovernance__PendingGovernanceAlreadySet(pendingGovernance);
        }
        pendingGovernance = newGovernance;
        emit GovernanceTransferProposed(governanceAdmin, newGovernance);
    }

    // slither-disable-start reentrancy-events
    /// @inheritdoc IOllaGovernance
    function acceptGovernance() external override {
        if (msg.sender != pendingGovernance) {
            revert OllaGovernance__UnauthorizedPendingGovernance(msg.sender);
        }
        address oldGovernance = governanceAdmin;
        address newGovernance = pendingGovernance;
        pendingGovernance = address(0);
        governanceAdmin = newGovernance;

        // Transfer timelock roles (proposer, executor, canceller) to the new governance
        _grantRole(PROPOSER_ROLE, newGovernance);
        _grantRole(EXECUTOR_ROLE, newGovernance);
        _grantRole(CANCELLER_ROLE, newGovernance);
        _grantRole(DEFAULT_ADMIN_ROLE, newGovernance);

        // Propagate DEFAULT_ADMIN_ROLE on satellite contracts
        _propagateAdminRole(oldGovernance, newGovernance);

        // Revoke roles from the old governance
        if (oldGovernance != address(0) && oldGovernance != newGovernance) {
            _revokeRole(PROPOSER_ROLE, oldGovernance);
            _revokeRole(EXECUTOR_ROLE, oldGovernance);
            _revokeRole(CANCELLER_ROLE, oldGovernance);
            _revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
        }

        emit GovernanceTransferAccepted(oldGovernance, newGovernance);
    }

    // slither-disable-end reentrancy-events

    /// @inheritdoc IOllaGovernance
    function cancelGovernanceProposal() external override onlySelf {
        if (pendingGovernance == address(0)) {
            revert OllaGovernance__NoPendingGovernance();
        }
        address pending = pendingGovernance;
        pendingGovernance = address(0);
        emit GovernanceTransferCancelled(pending);
    }

    /*//////////////////////////////////////////////////////////////
                         TREASURY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaGovernance
    function setTreasury(address newTreasury) external override onlySelf {
        if (newTreasury == address(0)) {
            revert OllaGovernance__ZeroAddress("newTreasury");
        }
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /*//////////////////////////////////////////////////////////////
                    OLLACORE PARAMETER PASSTHROUGHS
    //////////////////////////////////////////////////////////////*/

    // slither-disable-start pess-event-setter
    /// @inheritdoc IOllaGovernance
    function setProtocolFeeBP(uint256 newFeeBP) external override onlySelf {
        IOllaCore(core).setProtocolFeeBP(newFeeBP);
    }

    /// @inheritdoc IOllaGovernance
    function setTreasuryFeeSplitBP(uint256 newSplitBP) external override onlySelf {
        IOllaCore(core).setTreasuryFeeSplitBP(newSplitBP);
    }

    /// @inheritdoc IOllaGovernance
    function setTargetBufferedAssets(uint256 newBuffer) external override onlySelf {
        IOllaCore(core).setTargetBufferedAssets(newBuffer);
    }

    /// @inheritdoc IOllaGovernance
    function setRebalanceGasThreshold(uint256 newThreshold) external override onlySelf {
        IOllaCore(core).setRebalanceGasThreshold(newThreshold);
    }

    /// @inheritdoc IOllaGovernance
    function setSafetyModule(address newSafetyModule) external override onlySelf {
        IOllaCore(core).setSafetyModule(newSafetyModule);
    }

    /// @inheritdoc IOllaGovernance
    function setRebalanceCooldown(uint256 cooldown_) external override onlySelf {
        IOllaCore(core).setRebalanceCooldown(cooldown_);
    }

    /*//////////////////////////////////////////////////////////////
                    OLLAVAULT PARAMETER PASSTHROUGHS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaGovernance
    function setInstantRedemptionFeeBP(uint256 newFeeBP) external override onlySelf {
        IOllaVault(IOllaCore(core).vault()).setInstantRedemptionFeeBP(newFeeBP);
    }

    /// @inheritdoc IOllaGovernance
    function recoverStAztec(address recipient, uint256 amount) external override onlySelf {
        IOllaVault(IOllaCore(core).vault()).recoverStAztec(recipient, amount);
    }

    /// @inheritdoc IOllaGovernance
    function reconcileBufferedAssets() external override onlySelf {
        // slither-disable-next-line unused-return
        IOllaVault(IOllaCore(core).vault()).reconcileBufferedAssets();
    }

    /*//////////////////////////////////////////////////////////////
                   SAFETY MODULE PARAMETER PASSTHROUGHS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaGovernance
    function setDepositCap(uint256 cap) external override onlySelf {
        ISafetyModule(IOllaCore(core).safetyModule()).setDepositCap(cap);
    }

    /// @inheritdoc IOllaGovernance
    function setWithdrawalMinimum(uint256 minShares) external override onlySelf {
        ISafetyModule(IOllaCore(core).safetyModule()).setWithdrawalMinimum(minShares);
    }

    /// @inheritdoc IOllaGovernance
    function setMinRateDropBps(uint256 bps) external override onlySelf {
        ISafetyModule(IOllaCore(core).safetyModule()).setMinRateDropBps(bps);
    }

    /// @inheritdoc IOllaGovernance
    function setMaxQueueRatioBps(uint256 bps) external override onlySelf {
        ISafetyModule(IOllaCore(core).safetyModule()).setMaxQueueRatioBps(bps);
    }

    /// @inheritdoc IOllaGovernance
    function setMaxAccountingDelay(uint256 delay) external override onlySelf {
        ISafetyModule(IOllaCore(core).safetyModule()).setMaxAccountingDelay(delay);
    }

    // slither-disable-end pess-event-setter

    /*//////////////////////////////////////////////////////////////
                          UPGRADE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaGovernance
    function upgradeCore(address newImplementation) external override onlySelf {
        if (newImplementation == address(0)) {
            revert OllaGovernance__ZeroAddress("newImplementation");
        }
        UUPSUpgradeable(core).upgradeToAndCall(newImplementation, "");
    }

    /// @inheritdoc IOllaGovernance
    function upgradeSatellite(address proxy, address newImplementation) external override onlySelf {
        if (proxy == address(0)) {
            revert OllaGovernance__ZeroAddress("proxy");
        }
        if (newImplementation == address(0)) {
            revert OllaGovernance__ZeroAddress("newImplementation");
        }
        UUPSUpgradeable(proxy).upgradeToAndCall(newImplementation, "");
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Propagates DEFAULT_ADMIN_ROLE changes to all satellite contracts.
    /// @param oldGovernance The old governance address to revoke from.
    /// @param newGovernance The new governance address to grant to.
    function _propagateAdminRole(address oldGovernance, address newGovernance) internal {
        address coreAddr = core;
        address vaultAddr = IOllaCore(coreAddr).vault();
        address rv = IOllaCore(coreAddr).rewardsAccumulator();
        address sm = IOllaCore(coreAddr).stakingManager();
        address spr = address(IStakingManager(sm).stakingProviderRegistry());

        // Grant DEFAULT_ADMIN_ROLE to new governance on all satellites
        AccessControlUpgradeable(vaultAddr).grantRole(DEFAULT_ADMIN_ROLE, newGovernance);
        AccessControlUpgradeable(rv).grantRole(DEFAULT_ADMIN_ROLE, newGovernance);
        AccessControlUpgradeable(sm).grantRole(DEFAULT_ADMIN_ROLE, newGovernance);
        AccessControlUpgradeable(spr).grantRole(DEFAULT_ADMIN_ROLE, newGovernance);

        // Revoke from old governance
        if (oldGovernance != address(0) && oldGovernance != newGovernance) {
            AccessControlUpgradeable(vaultAddr).revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
            AccessControlUpgradeable(rv).revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
            AccessControlUpgradeable(sm).revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
            AccessControlUpgradeable(spr).revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
        }
    }

    /// @notice Authorizes UUPS upgrades. Only the timelock (self) can upgrade this contract.
    /// @param newImplementation The new implementation address to authorize.
    function _authorizeUpgrade(address newImplementation) internal view override onlySelf {
        if (newImplementation == address(0)) {
            revert OllaGovernance__ZeroAddress("newImplementation");
        }
    }
}
