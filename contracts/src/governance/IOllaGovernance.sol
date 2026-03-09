// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

/// @title IOllaGovernance
/// @notice Interface for the OllaGovernance contract.
/// @author Olla Core contributors
interface IOllaGovernance {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the treasury address is updated.
    /// @param oldTreasury The previous treasury address.
    /// @param newTreasury The new treasury address.
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when a new governance transfer is proposed.
    /// @param proposer The address that proposed the transfer.
    /// @param newGovernance The proposed new governance address.
    event GovernanceTransferProposed(address indexed proposer, address indexed newGovernance);

    /// @notice Emitted when a governance transfer is accepted.
    /// @param oldGovernance The previous governance address (proposer/executor/canceller).
    /// @param newGovernance The new governance address.
    event GovernanceTransferAccepted(address indexed oldGovernance, address indexed newGovernance);

    /// @notice Emitted when a pending governance transfer is cancelled.
    /// @param pendingGovernance The cancelled pending governance address.
    event GovernanceTransferCancelled(address indexed pendingGovernance);

    /// @notice Emitted when the core contract reference is set.
    /// @param core The OllaCore contract address.
    event CoreSet(address indexed core);

    /// @notice Emitted when a grantRole or revokeRole call fails during admin role propagation.
    /// @dev Governance should retry the failed operation via a timelock-scheduled call.
    /// @param satellite The satellite contract where the call failed.
    /// @param account The account that was being granted/revoked.
    /// @param isGrant True if the failed call was grantRole, false if revokeRole.
    event AdminRolePropagationFailed(address indexed satellite, address indexed account, bool indexed isGrant);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by someone other than address(this) (timelock self-call).
    error OllaGovernance__OnlySelf();

    /// @notice Thrown when a zero address is provided.
    error OllaGovernance__ZeroAddress(string param);

    /// @notice Thrown when the core contract has already been set.
    error OllaGovernance__CoreAlreadySet();

    /// @notice Thrown when a governance transfer is already pending.
    error OllaGovernance__PendingGovernanceAlreadySet(address pendingGovernance);

    /// @notice Thrown when no governance transfer is pending.
    error OllaGovernance__NoPendingGovernance();

    /// @notice Thrown when the caller is not the pending governance.
    error OllaGovernance__UnauthorizedPendingGovernance(address caller);

    /*//////////////////////////////////////////////////////////////
                             INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the governance contract with timelock configuration.
    /// @param minDelay The minimum delay for timelock operations.
    /// @param proposers The addresses that can schedule operations.
    /// @param executors The addresses that can execute operations.
    /// @param admin The admin address for role management.
    /// @param treasury_ The initial treasury address.
    function initialize(
        uint256 minDelay,
        address[] calldata proposers,
        address[] calldata executors,
        address admin,
        address treasury_
    ) external;

    /*//////////////////////////////////////////////////////////////
                         GOVERNANCE TRANSFER
    //////////////////////////////////////////////////////////////*/

    /// @notice Proposes a new governance address (proposer/executor/canceller roles).
    /// @dev Must be called through the timelock (onlySelf). The new governance must call
    ///      acceptGovernance() to complete the transfer.
    /// @param newGovernance The proposed new governance address.
    function proposeGovernance(address newGovernance) external;

    /// @notice Accepts governance by the pending governance address.
    /// @dev NOT timelocked - must be called directly by the pending governance address.
    ///      Atomically transfers proposer/executor/canceller roles and propagates
    ///      DEFAULT_ADMIN_ROLE changes across all satellite contracts.
    function acceptGovernance() external;

    /// @notice Cancels a pending governance proposal.
    /// @dev Must be called through the timelock (onlySelf).
    function cancelGovernanceProposal() external;

    /*//////////////////////////////////////////////////////////////
                         TREASURY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the treasury address.
    /// @dev Must be called through the timelock (onlySelf).
    /// @param newTreasury The new treasury address.
    function setTreasury(address newTreasury) external;

    /*//////////////////////////////////////////////////////////////
                    OLLACORE PARAMETER PASSTHROUGHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the protocol fee in basis points on OllaCore.
    /// @param newFeeBP The new fee.
    function setProtocolFeeBP(uint256 newFeeBP) external;

    /// @notice Sets the treasury fee split in basis points on OllaCore.
    /// @param newSplitBP The new split.
    function setTreasuryFeeSplitBP(uint256 newSplitBP) external;

    /// @notice Sets the target buffer on OllaCore.
    /// @param newBuffer The new target buffer.
    function setTargetBufferedAssets(uint256 newBuffer) external;

    /// @notice Sets the rebalance gas threshold on OllaCore.
    /// @param newThreshold The new gas threshold.
    function setRebalanceGasThreshold(uint256 newThreshold) external;

    /// @notice Sets the safety module address on OllaCore.
    /// @param newSafetyModule The new safety module address.
    function setSafetyModule(address newSafetyModule) external;

    /// @notice Sets the rebalance cooldown on OllaCore.
    /// @param cooldown_ The new cooldown in seconds.
    function setRebalanceCooldown(uint256 cooldown_) external;

    /*//////////////////////////////////////////////////////////////
                    OLLAVAULT PARAMETER PASSTHROUGHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the instant redemption fee on OllaVault.
    /// @param newFeeBP The new fee (0-2000).
    function setInstantRedemptionFeeBP(uint256 newFeeBP) external;

    /// @notice Recovers stAztec from OllaVault.
    /// @param recipient The recipient of the recovered stAztec.
    /// @param amount The amount of stAztec to recover.
    function recoverStAztec(address recipient, uint256 amount) external;

    /// @notice Reconciles buffered assets on OllaVault.
    function reconcileBufferedAssets() external;

    /*//////////////////////////////////////////////////////////////
                   SAFETY MODULE PARAMETER PASSTHROUGHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the deposit cap on the safety module.
    /// @param cap The new deposit cap.
    function setDepositCap(uint256 cap) external;

    /// @notice Sets the withdrawal minimum on the safety module.
    /// @param minShares The new minimum shares.
    function setWithdrawalMinimum(uint256 minShares) external;

    /// @notice Sets the minimum rate drop BPS on the safety module.
    /// @param bps The new minimum rate drop BPS.
    function setMinRateDropBps(uint256 bps) external;

    /// @notice Sets the maximum queue ratio BPS on the safety module.
    /// @param bps The new maximum queue ratio BPS.
    function setMaxQueueRatioBps(uint256 bps) external;

    /// @notice Sets the maximum accounting delay on the safety module.
    /// @param delay The new maximum accounting delay.
    function setMaxAccountingDelay(uint256 delay) external;

    /*//////////////////////////////////////////////////////////////
                          UPGRADE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Upgrades the OllaCore implementation.
    /// @param newImplementation The new implementation address.
    function upgradeCore(address newImplementation) external;

    /// @notice Upgrades a satellite contract implementation.
    /// @param proxy The proxy address of the satellite.
    /// @param newImplementation The new implementation address.
    function upgradeSatellite(address proxy, address newImplementation) external;

    /*//////////////////////////////////////////////////////////////
                          SETUP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time setter for the OllaCore contract reference.
    /// @param core_ The OllaCore contract address.
    function setCore(address core_) external;

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the OllaCore contract this governance manages.
    /// @return The OllaCore contract address.
    function core() external view returns (address);

    /// @notice Returns the treasury address where fees are sent.
    /// @return The treasury address.
    function treasury() external view returns (address);

    /// @notice Returns the pending governance address for two-step transfer.
    /// @return The pending governance address.
    function pendingGovernance() external view returns (address);
}
