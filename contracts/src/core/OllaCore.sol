// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { SafeCast } from "@oz/utils/math/SafeCast.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { IStAztec } from "src/core/interfaces/IStAztec.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { RolesLib } from "src/shared/RolesLib.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

/// @title OllaCore
/// @notice Core vault handling deposits and async withdrawals.
/// @author Olla Core contributors
contract OllaCore is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IOllaCore
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    enum Bucket {
        Buffered,
        StakedPrincipal,
        RewardsVault,
        RewardsDelta,
        SlashingDelta
    }

    uint256 private constant _EXCHANGE_RATE_SCALE = 1e18;
    uint256 private constant _REBALANCE_GAS_THRESHOLD = 180_000;

    /// @notice Role for guardian pause/unpause actions.
    bytes32 public constant GUARDIAN_ROLE = RolesLib.GUARDIAN_ROLE;
    /// @notice Role for operator accounting actions.
    bytes32 public constant OPERATOR_ROLE = RolesLib.OPERATOR_ROLE;

    /// @notice Basis points divisor.
    uint256 public constant BP_DIVISOR = 10_000;

    /// @notice Maximum protocol fee: 50%.
    uint256 public constant MAX_PROTOCOL_FEE_BP = 5_000;
    /// @notice Maximum instant redemption fee: 20%.
    uint256 public constant MAX_INSTANT_REDEMPTION_FEE_BP = 2_000;
    /// @notice Minimum treasury fee split: 10%.
    uint256 public constant MIN_TREASURY_SPLIT_BP = 1_000;
    /// @notice Maximum treasury fee split: 90%.
    uint256 public constant MAX_TREASURY_SPLIT_BP = 9_000;
    /// @notice Minimum rebalance gas threshold.
    uint256 public constant MIN_REBALANCE_GAS_THRESHOLD = 20_000;
    /// @notice Maximum rebalance gas threshold.
    uint256 public constant MAX_REBALANCE_GAS_THRESHOLD = 1_000_000;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract related interfaces and addresses
    IOllaCore.Modules private _modules;

    /// @notice Accounting and reporting values
    IOllaCore.AccountingState private _accountingState;
    IOllaCore.FlowCounters private _flowCounters;
    IOllaCore.LatestReport private _latestReport;

    IOllaCore.RebalanceProgress private _rebalanceProgress;

    bool private _rebalancePaused;
    uint8 private _rebalancePauseReason;
    uint256 private _rebalanceRequiredBufferSnapshot;

    /// @notice The protocol fee in basis points.
    uint256 public protocolFeeBP;

    /// @notice The treasury fee split in basis points.
    uint256 public treasuryFeeSplitBP;

    /// @notice Target liquid assets to keep buffered for withdrawals.
    uint256 public targetBufferedAssets;

    /// @notice Gas threshold used to gate rebalance step execution.
    uint256 public rebalanceGasThreshold;

    uint256 private _finalizedUnclaimedAssets;

    /// @notice Snapshot of bufferedAssets at the end of an unproductive rebalance cycle.
    ///         When nonzero and equal to the current bufferedAssets, rebalance skips starting
    ///         a new cycle because the previous cycle proved there is no productive work.
    ///         Reset to zero on any deposit, withdrawal request, or target-buffer change.
    uint256 private _rebalanceIdleBuffer;

    mapping(uint256 requestId => address owner) private _requestOwners;
    mapping(address owner => uint256[] requestIds) private _ownerRequestIds;
    mapping(uint256 requestId => uint256 index) private _ownerRequestIndex;

    /// @notice The instant redemption fee in basis points (0-10000).
    uint256 public instantRedemptionFeeBP;

    /// @notice Pending governance address for two-step transfer.
    /// @dev This variable persists across UUPS proxy upgrades. A pending governance proposal set before
    ///      an upgrade will remain active after the upgrade. This is expected behavior — callers should
    ///      either accept or cancel any pending proposal before upgrading.
    address private _pendingGovernance;

    /// @notice Storage gap for upgradability.
    /// @dev State variables occupy 40 slots (including struct members). When adding new state
    ///      variables, append them above this gap and reduce its length by the number of slots consumed.
    // slither-disable-next-line unused-state
    uint256[46] private __gap;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a caller is not governance.
    error OllaCore__UnauthorizedGovernance(address caller);

    /// @notice Thrown when a bucket lacks sufficient balance.
    error OllaCore__InsufficientBucketBalance(Bucket bucket, uint256 amount, uint256 available);

    /// @notice Thrown when buffered assets do not match the vault balance.
    error OllaCore__BufferedBalanceMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when queue assets do not match stored request data.
    error OllaCore__ClaimAssetsMismatch(uint256 requestId, uint256 expected, uint256 actual);

    modifier whenNotRebalancePaused() {
        if (_rebalancePaused) {
            revert OllaCore__RebalancePaused();
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
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOllaCore
    function initialize(
        IERC20 asset_,
        IStAztec stAztec_,
        IStakingManager stakingManager_,
        uint256 protocolFeeBP_,
        uint256 treasuryFeeSplitBP_,
        address governance_,
        address withdrawalQueue_,
        IRewardsVault rewardsVault_,
        address safetyModule_
    ) external override initializer {
        _validateInitialParams(
            asset_,
            stAztec_,
            stakingManager_,
            protocolFeeBP_,
            treasuryFeeSplitBP_,
            governance_,
            withdrawalQueue_,
            rewardsVault_,
            safetyModule_
        );
        __AccessControl_init();
        __Pausable_init();
        _pause();

        _modules = IOllaCore.Modules({
            asset: asset_,
            stAztec: stAztec_,
            stakingManager: stakingManager_,
            governance: governance_,
            withdrawalQueue: IWithdrawalQueue(withdrawalQueue_),
            rewardsVault: rewardsVault_,
            safetyModule: safetyModule_
        });

        protocolFeeBP = protocolFeeBP_;
        treasuryFeeSplitBP = treasuryFeeSplitBP_;

        // targetBufferedAssets defaults to zero intentionally. Early in the protocol lifecycle
        // there is no need for a liquidity buffer; governance can increase it via setTargetBufferedAssets()
        // once withdrawal volume justifies reserving idle capital.
        targetBufferedAssets = 0;
        rebalanceGasThreshold = _REBALANCE_GAS_THRESHOLD;
        _rebalanceProgress.step = IOllaCore.RebalanceStep.Done;

        _modules.stakingManager.setGasThreshold(rebalanceGasThreshold);
        _modules.withdrawalQueue.setGasThreshold(rebalanceGasThreshold);

        _latestReport.exchangeRate = _EXCHANGE_RATE_SCALE;
        // Timestamp is used only for reporting/accounting liveness.
        // slither-disable-next-line timestamp
        _latestReport.timestamp = block.timestamp;

        instantRedemptionFeeBP = 500; // 5% default instant redemption fee

        // Governance receives all three roles (DEFAULT_ADMIN_ROLE,
        // GUARDIAN_ROLE, OPERATOR_ROLE) at init; the deployer is expected to be a trusted governance
        // address. Role separation is available immediately after deployment.
        _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, governance_);
        _grantRole(GUARDIAN_ROLE, governance_);
        _grantRole(OPERATOR_ROLE, governance_);
    }

    /// @notice Deposits assets and mints stAztec shares.
    /// @param assets The amount of assets to deposit.
    /// @param recipient The recipient of the stAztec shares.
    /// @param minSharesOut The minimum shares the caller expects; set 0 to skip the check.
    /// @return shares The shares minted to the recipient.
    function deposit(uint256 assets, address recipient, uint256 minSharesOut)
        external
        override
        nonReentrant
        whenNotPaused
        whenNotRebalancePaused
        returns (uint256 shares)
    {
        shares = _deposit(msg.sender, assets, recipient);
        // Slither: slippage guard, not a timestamp comparison.
        // slither-disable-next-line timestamp
        if (shares < minSharesOut) revert OllaCore__SlippageExceeded(shares, minSharesOut);
        return shares;
    }

    /// @notice Deposits assets with a permit signature and mints stAztec shares.
    /// @param assets The amount of assets to deposit.
    /// @param recipient The recipient of the stAztec shares.
    /// @param minSharesOut The minimum shares the caller expects; set 0 to skip the check.
    /// @param deadline The permit deadline timestamp.
    /// @param v The permit signature v.
    /// @param r The permit signature r.
    /// @param s The permit signature s.
    /// @return shares The shares minted to the recipient.
    function depositWithPermit(
        uint256 assets,
        address recipient,
        uint256 minSharesOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant whenNotPaused whenNotRebalancePaused returns (uint256 shares) {
        // Slither: permit is a signature validation with no state side effects; function is nonReentrant.
        // slither-disable-next-line reentrancy-benign
        IERC20Permit(address(_modules.asset)).permit(msg.sender, address(this), assets, deadline, v, r, s);
        shares = _deposit(msg.sender, assets, recipient);
        // Slither: slippage guard, not a timestamp comparison.
        // slither-disable-next-line timestamp
        if (shares < minSharesOut) revert OllaCore__SlippageExceeded(shares, minSharesOut);
        return shares;
    }

    /// @notice Requests a redemption in shares.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the assets.
    /// @return requestId The withdrawal request id.
    function requestRedeem(uint256 shares, address recipient)
        external
        override
        nonReentrant
        whenNotPaused
        whenNotRebalancePaused
        returns (uint256 requestId)
    {
        requestId = _requestRedeem(msg.sender, shares, recipient);
        return requestId;
    }

    /// @notice Requests a redemption in shares with a permit signature.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the assets.
    /// @param deadline The permit deadline timestamp.
    /// @param v The permit signature v.
    /// @param r The permit signature r.
    /// @param s The permit signature s.
    /// @return requestId The withdrawal request id.
    function requestRedeemWithPermit(
        uint256 shares,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant whenNotPaused whenNotRebalancePaused returns (uint256 requestId) {
        // slither-disable-next-line reentrancy-benign
        _modules.stAztec.permit(msg.sender, address(this), shares, deadline, v, r, s);
        requestId = _requestRedeem(msg.sender, shares, recipient);
        return requestId;
    }

    /// @notice Claims a finalized withdrawal request by id.
    /// @dev This function is intentionally permissionless — any address can trigger a claim.
    ///      Assets are always sent to the original request recipient, not msg.sender, so there is
    ///      no theft vector. This allows third-party relayers or keepers to process claims on behalf
    ///      of users.
    /// @param requestId The withdrawal request id.
    /// @return assets The assets claimed for the request.
    function claimRequestById(uint256 requestId) external override nonReentrant whenNotPaused returns (uint256 assets) {
        // Trust: withdrawal queue is authoritative for request state and asset amounts.
        assets = _claimWithdrawal(requestId);
        return assets;
    }

    /// @notice Instantly redeems stAztec shares for AZTEC assets, charging an instant redemption fee.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the net assets.
    /// @param minAssetsOut The minimum net assets the caller expects; set 0 to skip the check.
    /// @return assetsAfterFee The net assets transferred to the recipient.
    function redeem(uint256 shares, address recipient, uint256 minAssetsOut)
        external
        override
        nonReentrant
        whenNotPaused
        whenNotRebalancePaused
        returns (uint256 assetsAfterFee)
    {
        assetsAfterFee = _redeem(msg.sender, shares, recipient);
        // Slither: slippage guard, not a timestamp comparison.
        // slither-disable-next-line timestamp
        if (assetsAfterFee < minAssetsOut) revert OllaCore__SlippageExceeded(assetsAfterFee, minAssetsOut);
        return assetsAfterFee;
    }

    /// @notice Instantly redeems stAztec shares for AZTEC assets with a permit signature.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the net assets.
    /// @param minAssetsOut The minimum net assets the caller expects; set 0 to skip the check.
    /// @param deadline The permit deadline timestamp.
    /// @param v The permit signature v.
    /// @param r The permit signature r.
    /// @param s The permit signature s.
    /// @return assetsAfterFee The net assets transferred to the recipient.
    function redeemWithPermit(
        uint256 shares,
        address recipient,
        uint256 minAssetsOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant whenNotPaused whenNotRebalancePaused returns (uint256 assetsAfterFee) {
        // Slither: permit is a signature validation with no state side effects; function is nonReentrant.
        // slither-disable-next-line reentrancy-benign
        _modules.stAztec.permit(msg.sender, address(this), shares, deadline, v, r, s);
        assetsAfterFee = _redeem(msg.sender, shares, recipient);
        // Slither: slippage guard, not a timestamp comparison.
        // slither-disable-next-line timestamp
        if (assetsAfterFee < minAssetsOut) revert OllaCore__SlippageExceeded(assetsAfterFee, minAssetsOut);
        return assetsAfterFee;
    }

    /*//////////////////////////////////////////////////////////////
                      PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses deposits and withdrawals.
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        _pause();
        emit Paused();
    }

    /// @notice Unpauses deposits and withdrawals.
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        _unpause();
        emit Unpaused();
    }

    /// @inheritdoc IOllaCore
    function forceRebalanceUnpause() external override onlyRole(GUARDIAN_ROLE) whenNotPaused {
        if (!_rebalancePaused) {
            revert OllaCore__RebalancePauseOverrideNotAllowed();
        }

        // Reset state machine to Done
        _rebalanceProgress =
            IOllaCore.RebalanceProgress({ step: IOllaCore.RebalanceStep.Done, stakeRemaining: 0, unstakeRemaining: 0 });

        _rebalancePaused = false;
        _rebalancePauseReason = uint8(IOllaCore.RebalancePauseReason.GovernanceOverride);
        _rebalanceRequiredBufferSnapshot = 0;
        _rebalanceIdleBuffer = 0;

        emit RebalancePauseUpdated(false, IOllaCore.RebalancePauseReason.GovernanceOverride);
    }

    /// @notice Sets the protocol fee in basis points.
    /// @param newFeeBP The new fee (0-5000).
    function setProtocolFeeBP(uint256 newFeeBP)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        whenNotRebalancePaused
    {
        if (newFeeBP > MAX_PROTOCOL_FEE_BP) {
            revert OllaCore__InvalidFeeBP(newFeeBP);
        }
        uint256 oldFeeBP = protocolFeeBP;
        protocolFeeBP = newFeeBP;
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);
    }

    /// @notice Sets the treasury fee split in basis points.
    /// @param newSplitBP The new split (1000-9000).
    function setTreasuryFeeSplitBP(uint256 newSplitBP)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        whenNotRebalancePaused
    {
        if (newSplitBP < MIN_TREASURY_SPLIT_BP || newSplitBP > MAX_TREASURY_SPLIT_BP) {
            revert OllaCore__InvalidSplitBP(newSplitBP);
        }
        uint256 oldSplitBP = treasuryFeeSplitBP;
        treasuryFeeSplitBP = newSplitBP;
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);
    }

    /// @notice Proposes a new governance address.
    /// @param newGovernance The proposed governance address.
    function proposeGovernance(address newGovernance)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        whenNotRebalancePaused
    {
        if (newGovernance == address(0)) {
            revert OllaCore__ZeroAddress("newGovernance");
        }
        if (_pendingGovernance != address(0)) {
            revert OllaCore__PendingGovernanceAlreadySet(_pendingGovernance);
        }
        _pendingGovernance = newGovernance;
        emit GovernanceProposed(_modules.governance, newGovernance);
    }

    /// @notice Accepts governance by the pending governance address.
    // Slither: satellite contracts are trusted protocol-owned modules; external grantRole/revokeRole
    // calls do not introduce reentrancy risk. Multiple _modules reads are acceptable for clarity.
    // slither-disable-next-line reentrancy-events,pess-multiple-storage-read
    function acceptGovernance() external override whenNotPaused whenNotRebalancePaused {
        if (msg.sender != _pendingGovernance) {
            revert OllaCore__UnauthorizedPendingGovernance(msg.sender);
        }
        address oldGovernance = _modules.governance;
        address newGovernance = _pendingGovernance;
        _modules.governance = newGovernance;
        _pendingGovernance = address(0);

        // Transfer governance-related roles from the old governance to the new one
        if (newGovernance != oldGovernance) {
            // Cache the staking provider registry address to avoid two external calls
            // slither-disable-next-line unused-return
            address stakingProviderRegistryAddr = address(_modules.stakingManager.stakingProviderRegistry());

            // Grant roles to the new governance address first (before revoking from old)
            _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, newGovernance);
            _grantRole(GUARDIAN_ROLE, newGovernance);
            _grantRole(OPERATOR_ROLE, newGovernance);

            // Propagate DEFAULT_ADMIN_ROLE grant to satellite contracts
            AccessControlUpgradeable(address(_modules.withdrawalQueue)).grantRole(DEFAULT_ADMIN_ROLE, newGovernance);
            AccessControlUpgradeable(address(_modules.rewardsVault)).grantRole(DEFAULT_ADMIN_ROLE, newGovernance);
            AccessControlUpgradeable(address(_modules.stakingManager)).grantRole(DEFAULT_ADMIN_ROLE, newGovernance);
            AccessControlUpgradeable(stakingProviderRegistryAddr).grantRole(DEFAULT_ADMIN_ROLE, newGovernance);

            // Revoke roles from the old governance address
            if (oldGovernance != address(0)) {
                _revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
                _revokeRole(GUARDIAN_ROLE, oldGovernance);
                _revokeRole(OPERATOR_ROLE, oldGovernance);

                // Propagate DEFAULT_ADMIN_ROLE revoke from satellite contracts
                AccessControlUpgradeable(address(_modules.withdrawalQueue))
                    .revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
                AccessControlUpgradeable(address(_modules.rewardsVault)).revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
                AccessControlUpgradeable(address(_modules.stakingManager)).revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
                AccessControlUpgradeable(stakingProviderRegistryAddr).revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
            }
        }
        emit GovernanceAccepted(oldGovernance, newGovernance);
    }

    /// @notice Cancels a pending governance proposal.
    function cancelGovernanceProposal()
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        whenNotRebalancePaused
    {
        if (_pendingGovernance == address(0)) {
            revert OllaCore__NoPendingGovernance();
        }
        address pending = _pendingGovernance;
        _pendingGovernance = address(0);
        emit GovernanceProposalCancelled(_modules.governance, pending);
    }

    /// @notice Sets the safety module address.
    /// @param newSafetyModule The new safety module address.
    function setSafetyModule(address newSafetyModule)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        whenNotRebalancePaused
    {
        if (newSafetyModule == address(0)) {
            revert OllaCore__ZeroAddress("newSafetyModule");
        }
        if (ISafetyModule(newSafetyModule).CORE() != address(this)) {
            revert OllaCore__InvalidSafetyModule(newSafetyModule);
        }
        address oldSafetyModule = _modules.safetyModule;
        _modules.safetyModule = newSafetyModule;
        emit SafetyModuleUpdated(oldSafetyModule, newSafetyModule);
    }

    /// @notice Sets the target buffer used to reserve liquid assets.
    /// @param newBuffer The new target buffer.
    function setTargetBufferedAssets(uint256 newBuffer)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        whenNotRebalancePaused
    {
        uint256 oldBuffer = targetBufferedAssets;
        targetBufferedAssets = newBuffer;
        _rebalanceIdleBuffer = 0;
        emit TargetBufferedAssetsUpdated(oldBuffer, newBuffer);
    }

    /// @notice Sets the gas threshold used for rebalance step gating.
    /// @param newThreshold The new gas threshold (20000-1000000).
    function setRebalanceGasThreshold(uint256 newThreshold)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        whenNotRebalancePaused
    {
        if (newThreshold < MIN_REBALANCE_GAS_THRESHOLD || newThreshold > MAX_REBALANCE_GAS_THRESHOLD) {
            revert OllaCore__InvalidGasThreshold(newThreshold);
        }
        uint256 oldThreshold = rebalanceGasThreshold;
        rebalanceGasThreshold = newThreshold;
        emit RebalanceGasThresholdUpdated(oldThreshold, newThreshold);
        _modules.stakingManager.setGasThreshold(newThreshold);
        _modules.withdrawalQueue.setGasThreshold(newThreshold);
    }

    /// @notice Sets the instant redemption fee in basis points.
    /// @param newFeeBP The new fee (0-2000).
    function setInstantRedemptionFeeBP(uint256 newFeeBP)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        whenNotRebalancePaused
    {
        if (newFeeBP > MAX_INSTANT_REDEMPTION_FEE_BP) {
            revert OllaCore__InvalidFeeBP(newFeeBP);
        }
        uint256 oldFeeBP = instantRedemptionFeeBP;
        instantRedemptionFeeBP = newFeeBP;
        emit InstantRedemptionFeeUpdated(oldFeeBP, newFeeBP);
    }

    // Slither: rebalance is a linear state machine; complexity is intentional and reviewed.
    // slither-disable-start cyclomatic-complexity
    // slither-disable-start pess-multiple-storage-read
    // slither-disable-start incorrect-equality
    // solhint-disable function-max-lines
    /// @notice Operator-triggered rebalance flow.
    /// @dev Executes: harvest (includes pulling rewards vault funds) -> pull unstaked ->
    /// @dev     finalize withdrawals -> initiate unstake -> stake surplus
    /// @return rewardsDelta The amount of rewards harvested.
    /// @return finalizedAmount The amount of assets used to finalize withdrawals.
    /// @return stakedAmount The amount staked.
    /// @return resultingBuffer The final buffered assets after rebalance.
    function rebalance()
        external
        override
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer)
    {
        ISafetyModule safetyModuleRef = ISafetyModule(_modules.safetyModule);
        // Trust: rebalance assumes safety module, staking manager, rewards vault, and withdrawal queue are trusted.
        // Slither: SafetyModule is a trusted dependency; rebalance is nonReentrant and role-gated.
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        safetyModuleRef.checkAccountingLiveness();
        IOllaCore.RebalanceProgress memory progress = _rebalanceProgress;

        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.Done) {
            // Guard: skip starting a new cycle if the previous cycle was unproductive
            // and no new work has become available.
            // New work can appear via: rewards vault funds, unstaked funds, pending withdrawals,
            // or config changes (which clear _rebalanceIdleBuffer).
            if (
                _rebalanceIdleBuffer != 0 && _accountingState.bufferedAssets == _rebalanceIdleBuffer
                    && !_hasRebalanceWorkAvailable()
            ) {
                return (0, 0, 0, _accountingState.bufferedAssets);
            }
            if (!_rebalancePaused) {
                _rebalancePaused = true;
                _rebalancePauseReason = uint8(IOllaCore.RebalancePauseReason.RebalanceStart);
                emit RebalancePauseUpdated(true, IOllaCore.RebalancePauseReason.RebalanceStart);
                (uint256 requiredBuffer,) = _computeRequiredBuffer();
                _rebalanceRequiredBufferSnapshot = requiredBuffer;
            }
            _rebalanceIdleBuffer = 0;
            _syncBufferedWithBalance();
            progress.step = IOllaCore.RebalanceStep.Harvest;
            progress.stakeRemaining = 0;
            progress.unstakeRemaining = 0;
        }

        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.Harvest) {
            // Slither: rebalance is nonReentrant and uses trusted modules for external calls.
            // slither-disable-next-line reentrancy-no-eth
            rewardsDelta = _harvestRewards();
            progress.step = IOllaCore.RebalanceStep.PullUnstaked;
        }

        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.PullUnstaked) {
            if (!_hasGasForStep()) {
                _rebalanceProgress = progress;
                return (rewardsDelta, 0, 0, _accountingState.bufferedAssets);
            }
            // slither-disable-next-line unused-return -- receivedAmount is not used here
            (, bool hasRemainingExits) = _pullUnstakedFunds();
            if (hasRemainingExits) {
                _rebalanceProgress = progress;
                return (rewardsDelta, 0, 0, _accountingState.bufferedAssets);
            }
            progress.step = IOllaCore.RebalanceStep.FinalizeWithdrawals;
        }

        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.FinalizeWithdrawals) {
            if (!_hasGasForStep()) {
                _rebalanceProgress = progress;
                return (rewardsDelta, 0, 0, _accountingState.bufferedAssets);
            }
            finalizedAmount = _finalizeWithdrawals();
            uint256 pending = _modules.withdrawalQueue.totalPendingAssets();
            // Slither: zero guard only; no timestamp usage.
            // slither-disable-next-line incorrect-equality,timestamp
            if (pending == 0 || _accountingState.bufferedAssets == 0 || finalizedAmount == 0) {
                (uint256 requiredBuffer,) = _computeRequiredBuffer();
                progress.unstakeRemaining = _computeUnstakeRemaining(requiredBuffer);
                progress.step = IOllaCore.RebalanceStep.InitiateUnstake;
            } else {
                _rebalanceProgress = progress;
                return (rewardsDelta, finalizedAmount, 0, _accountingState.bufferedAssets);
            }
        }

        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.InitiateUnstake) {
            // Slither: zero guard only; no timestamp usage.
            // slither-disable-next-line incorrect-equality,timestamp
            if (progress.unstakeRemaining == 0) {
                progress.step = IOllaCore.RebalanceStep.StakeSurplus;
            } else {
                if (!_hasGasForStep()) {
                    _rebalanceProgress = progress;
                    return (rewardsDelta, finalizedAmount, 0, _accountingState.bufferedAssets);
                }
                uint256 initiated = _initiateUnstake(progress.unstakeRemaining);
                if (initiated >= progress.unstakeRemaining) {
                    progress.unstakeRemaining = 0;
                } else {
                    progress.unstakeRemaining -= initiated;
                }

                // Slither: explicit nonzero check; no timestamp usage.
                // slither-disable-next-line timestamp
                if (progress.unstakeRemaining != 0) {
                    // Slither: zero return is an intentional sentinel for no progress
                    // slither-disable-next-line incorrect-equality
                    if (initiated == 0 && _modules.stakingManager.getActivatedAttesterCount() == 0) {
                        progress.unstakeRemaining = 0;
                        progress.step = IOllaCore.RebalanceStep.StakeSurplus;
                    } else {
                        _rebalanceProgress = progress;
                        return (rewardsDelta, finalizedAmount, 0, _accountingState.bufferedAssets);
                    }
                }
                progress.step = IOllaCore.RebalanceStep.StakeSurplus;
            }
        }

        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.StakeSurplus) {
            // Slither: zero guard only; no timestamp usage.
            // slither-disable-next-line incorrect-equality,timestamp
            if (progress.stakeRemaining == 0) {
                (uint256 requiredBuffer,) = _computeRequiredBuffer();
                progress.stakeRemaining = _computeStakeRemaining(requiredBuffer);
                // Slither: zero guard only; no timestamp usage.
                // slither-disable-next-line incorrect-equality,timestamp
                if (progress.stakeRemaining == 0) {
                    progress.step = IOllaCore.RebalanceStep.ComputeAttesterState;
                }
            }
            // Slither: enum state machine uses explicit equality checks; no timestamp usage.
            // slither-disable-next-line incorrect-equality,timestamp
            if (progress.step == IOllaCore.RebalanceStep.StakeSurplus) {
                if (!_hasGasForStep()) {
                    _rebalanceProgress = progress;
                    return (rewardsDelta, finalizedAmount, 0, _accountingState.bufferedAssets);
                }

                stakedAmount = _stakeSurplus(progress.stakeRemaining);
                progress.stakeRemaining -= stakedAmount;

                // Slither: explicit nonzero check; no timestamp usage.
                // slither-disable-next-line timestamp
                if (progress.stakeRemaining != 0) {
                    // Slither: zero return is an intentional sentinel for no progress
                    // slither-disable-next-line incorrect-equality
                    if (stakedAmount == 0) {
                        progress.stakeRemaining = 0;
                        progress.step = IOllaCore.RebalanceStep.ComputeAttesterState;
                    } else {
                        _rebalanceProgress = progress;
                        return (rewardsDelta, finalizedAmount, stakedAmount, _accountingState.bufferedAssets);
                    }
                }
                progress.step = IOllaCore.RebalanceStep.ComputeAttesterState;
            }
        }

        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.ComputeAttesterState) {
            if (!_hasGasForStep()) {
                _rebalanceProgress = progress;
                return (rewardsDelta, finalizedAmount, stakedAmount, _accountingState.bufferedAssets);
            }
            // slither-disable-next-line unused-return -- slashingDelta is cached inside computeAttesterState
            (, bool computeCompleted) = _modules.stakingManager.computeAttesterState();
            if (computeCompleted) {
                progress.step = IOllaCore.RebalanceStep.Done;
            } else {
                _rebalanceProgress = progress;
                return (rewardsDelta, finalizedAmount, stakedAmount, _accountingState.bufferedAssets);
            }
        }

        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.Done) {
            progress.stakeRemaining = 0;
            progress.unstakeRemaining = 0;
            // Record idle buffer when cycle completed with no productive staking/unstaking/finalization.
            // This prevents infinite restart loops when there is an unstakeable remainder
            // (e.g. buffer below staking minimum threshold).
            // slither-disable-next-line incorrect-equality,timestamp
            if (stakedAmount == 0 && finalizedAmount == 0 && rewardsDelta == 0) {
                _rebalanceIdleBuffer = _accountingState.bufferedAssets;
            } else {
                _rebalanceIdleBuffer = 0;
            }
        }

        _rebalanceProgress = progress;
        resultingBuffer = _accountingState.bufferedAssets;

        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step == IOllaCore.RebalanceStep.Done) {
            emit Rebalanced(rewardsDelta, finalizedAmount, stakedAmount, resultingBuffer);
        }

        IOllaCore.RebalanceProgress memory progressSnapshot = _rebalanceProgress;
        if (_rebalancePaused && _rebalanceCompletionSatisfied(progressSnapshot)) {
            _updateAccountingInternal();
            _rebalancePaused = false;
            _rebalancePauseReason = uint8(IOllaCore.RebalancePauseReason.RebalanceComplete);
            _rebalanceRequiredBufferSnapshot = 0;
            emit RebalancePauseUpdated(false, IOllaCore.RebalancePauseReason.RebalanceComplete);
        }

        return (rewardsDelta, finalizedAmount, stakedAmount, resultingBuffer);
    }

    // slither-disable-end pess-multiple-storage-read
    // slither-disable-end cyclomatic-complexity
    // slither-disable-end incorrect-equality
    // solhint-enable function-max-lines

    // Slither: accept multiple storage reads for readability in hot-path accounting.
    // Slither: accept multiple storage reads for readability in withdrawal finalization.
    // slither-disable-start pess-multiple-storage-read
    // solhint-disable function-max-lines
    /// @notice Updates accounting snapshots and publishes the latest exchange rate data.
    function updateAccounting()
        external
        override
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        whenNotRebalancePaused
        nonReentrant
    {
        // Slither: explicit state check; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (_rebalanceProgress.step != IOllaCore.RebalanceStep.Done) {
            revert OllaCore__RebalanceInProgress();
        }
        _updateAccountingInternal();
    }

    // solhint-enable function-max-lines

    // slither-disable-end pess-multiple-storage-read

    /// @notice Reconciles buffered assets with the actual asset balance.
    /// @return delta The amount added to buffered assets.
    function reconcileBufferedAssets()
        external
        override
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        whenNotRebalancePaused
        returns (uint256 delta)
    {
        delta = _reconcileBufferedAssets(address(this));
        return delta;
    }

    /// @notice Recovers stAztec sent directly to the core.
    /// @param recipient The recipient of the recovered stAztec (defaults to governance if zero).
    /// @param amount The amount of stAztec to recover.
    function recoverStAztec(address recipient, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        whenNotRebalancePaused
    {
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        address resolvedRecipient = recipient == address(0) ? _modules.governance : recipient;
        IERC20(address(_modules.stAztec)).safeTransfer(resolvedRecipient, amount);
        emit StAztecRecovered(amount, resolvedRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the underlying asset address.
    /// @return The underlying asset address.
    function asset() external view override returns (address) {
        return address(_modules.asset);
    }

    /// @notice Returns the stAztec share token address.
    /// @return The stAztec share token address.
    function stAztec() external view override returns (address) {
        return address(_modules.stAztec);
    }

    /// @notice Returns the staking manager address.
    /// @return The staking manager address.
    function stakingManager() external view override returns (address) {
        return address(_modules.stakingManager);
    }

    /// @notice Returns the recorded owner for a withdrawal request id.
    /// @param requestId The withdrawal request id.
    /// @return owner The request owner.
    function requestOwner(uint256 requestId) external view override returns (address owner) {
        return _requestOwners[requestId];
    }

    /// @notice Returns the active withdrawal request ids for an owner.
    /// @param owner The request owner.
    /// @return requestIds The active request ids.
    function activeRequestIds(address owner) external view override returns (uint256[] memory requestIds) {
        return _ownerRequestIds[owner];
    }

    /// @notice Returns the governance address.
    /// @return The governance address.
    function governance() external view override returns (address) {
        return _modules.governance;
    }

    /// @notice Returns the pending governance address.
    /// @return The pending governance address.
    function pendingGovernance() external view override returns (address) {
        return _pendingGovernance;
    }

    /// @notice Returns the withdrawal queue module address.
    /// @return The withdrawal queue address.
    function withdrawalQueue() external view override returns (address) {
        return address(_modules.withdrawalQueue);
    }

    /// @notice Returns the rewards vault module address.
    /// @return The rewards vault address.
    function rewardsVault() external view override returns (address) {
        return address(_modules.rewardsVault);
    }

    /// @notice Returns the safety module address.
    /// @return The safety module address.
    function safetyModule() external view override returns (address) {
        return _modules.safetyModule;
    }

    /// @notice Returns the latest accounting report snapshot.
    /// @return The latest report struct.
    function latestReport() external view override returns (IOllaCore.LatestReport memory) {
        return _latestReport;
    }

    /// @notice Returns the current rebalance progress snapshot.
    /// @return The rebalance progress struct.
    function rebalanceProgress() external view override returns (IOllaCore.RebalanceProgress memory) {
        return IOllaCore.RebalanceProgress({
            step: _rebalanceProgress.step,
            stakeRemaining: _rebalanceProgress.stakeRemaining,
            unstakeRemaining: _rebalanceProgress.unstakeRemaining
        });
    }

    /// @notice Returns whether rebalance pause is active.
    /// @return paused Whether rebalance pause is active.
    function isRebalancePaused() external view override returns (bool paused) {
        return _rebalancePaused;
    }

    /// @notice Returns the rebalance pause reason code.
    /// @return reason The pause reason code.
    function rebalancePauseReason() external view override returns (uint8 reason) {
        return _rebalancePauseReason;
    }

    /// @notice Returns the flow counter snapshots.
    /// @return The flow counters struct.
    function flowCounters() external view override returns (IOllaCore.FlowCounters memory) {
        return _flowCounters;
    }

    /// @notice Returns the accounting buckets snapshot.
    /// @return The accounting state struct.
    function accountingState() external view override returns (IOllaCore.AccountingState memory) {
        return _accountingState;
    }

    /// @notice Returns the current exchange rate in 18-decimal fixed-point units.
    /// @return The exchange rate scaled by 1e18.
    function exchangeRate() external view override returns (uint256) {
        return _exchangeRate();
    }

    /// @notice Computes the shares for an asset amount.
    /// @param assets The asset amount being converted.
    /// @return shares The shares that would be minted.
    /// Formula: assets * totalSupply / totalAssets (floor), assets if supply == 0.
    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Computes the assets for a share amount.
    /// @param shares The share amount being converted.
    /// @return assets The assets that would be returned.
    /// Formula: shares * totalAssets / totalSupply (floor), shares if supply == 0.
    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        return _convertToAssets(shares);
    }

    /// @notice Returns the shares previewed for a deposit.
    /// @param assets The asset amount being deposited.
    /// @return shares The shares that would be minted.
    function previewDeposit(uint256 assets) external view override returns (uint256 shares) {
        return _convertToSharesForDeposit(assets);
    }

    /// @notice Returns the net assets previewed for an instant redemption.
    /// @param shares The share amount being redeemed.
    /// @return assetsAfterFee The net assets after the instant redemption fee.
    function previewRedeem(uint256 shares) external view override returns (uint256 assetsAfterFee) {
        uint256 grossAssets = _convertToAssets(shares);
        uint256 fee = grossAssets * instantRedemptionFeeBP / BP_DIVISOR;
        assetsAfterFee = grossAssets - fee;
        return assetsAfterFee;
    }

    /// @notice Returns the maximum assets currently available for instant redemptions.
    /// @dev After reconciliation, `bufferedAssets` already equals `balance - _finalizedUnclaimedAssets`,
    ///      so it directly represents unencumbered liquid assets.
    /// @return available The unencumbered buffered assets available for instant redemptions.
    function availableForInstantRedemption() public view override returns (uint256 available) {
        return _accountingState.bufferedAssets;
    }

    /// @notice Returns the current total assets held by the vault.
    /// @return The total assets held by the vault.
    function totalAssets() public view override returns (uint256) {
        IOllaCore.AccountingState memory buckets = _accountingState;
        uint256 total =
            buckets.bufferedAssets + buckets.stakedPrincipal + buckets.rewardsVaultBalance + buckets.claimableRewards;
        // Slither: false positive — comparing asset amounts, not timestamps.
        // slither-disable-next-line timestamp
        return buckets.slashingDelta >= total ? 0 : total - buckets.slashingDelta;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _updateAccountingInternal() internal {
        ISafetyModule safetyModuleRef = ISafetyModule(_modules.safetyModule);
        // slither-disable-start reentrancy-no-eth
        // slither-disable-start reentrancy-benign
        // slither-disable-start reentrancy-events
        // SafetyModule is a trusted dependency; updateAccounting is nonReentrant and role-gated, so
        // fail-fast checks before accounting updates are safe.
        safetyModuleRef.checkAccountingLiveness();

        (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows) = _getFlowsSnapshot();
        (
            uint256 currentRewards,
            uint256 rewardsDelta,
            uint256 slashingDelta,
            uint256 stakedPrincipal,
            uint256 claimableRewards
        ) = _getStakingManagerState();
        _validateSlashingDelta(slashingDelta);

        uint256 rewardsVaultBalance = _getRewardsVaultBalance();

        _applyAccountingUpdates(stakedPrincipal, rewardsVaultBalance, claimableRewards, rewardsDelta, slashingDelta);

        _computeAndFinalizeAccounting(safetyModuleRef, flowsSnapshot, netFlows, currentRewards);
        // slither-disable-end reentrancy-events
        // slither-disable-end reentrancy-benign
        // slither-disable-end reentrancy-no-eth
    }

    function _deposit(address caller, uint256 assets, address recipient) internal returns (uint256 shares) {
        if (recipient == address(0)) {
            revert OllaCore__ZeroAddress("recipient");
        }
        if (assets == 0) {
            revert OllaCore__InvalidAmount();
        }

        Modules memory modules = _modules;

        if (ISafetyModule(modules.safetyModule).isPaused()) {
            revert OllaCore__SafetyModulePaused();
        }

        _syncBufferedWithBalance();

        uint256 currentTotalAssets = totalAssets();
        if (!ISafetyModule(modules.safetyModule).checkDepositAllowed(assets, currentTotalAssets)) {
            revert OllaCore__DepositCapExceeded(assets, currentTotalAssets);
        }

        shares = _convertToSharesForDeposit(assets);
        modules.asset.safeTransferFrom(caller, address(this), assets);
        _increaseBuffered(assets);
        _syncBufferedWithBalance();
        _increaseCumulativeDeposits(assets);

        modules.stAztec.mint(recipient, shares);
        emit Deposit(caller, recipient, assets, shares);
        return shares;
    }

    // Slither: reentrancy-no-eth is a false positive; _harvestRewards is only called from rebalance()
    // which is protected by nonReentrant. Multiple storage reads are acceptable for clarity.
    // slither-disable-next-line reentrancy-no-eth,pess-multiple-storage-read
    function _harvestRewards() internal returns (uint256 rewardsDelta) {
        // Trigger the actual claiming on the rollup (rewards are sent directly to RewardsVault)
        // We intentionally ignore the return value because rewards may be permissionlessly harvested.
        // The actual amount received is determined by delta from RewardsVault.recordBalance().
        // slither-disable-next-line unused-return
        _modules.stakingManager.harvestRewards();

        // Get the actual delta from RewardsVault and update cumulative rewards
        IRewardsVault rewardsVaultRef = _modules.rewardsVault;
        // slither-disable-next-line reentrancy-benign
        rewardsDelta = rewardsVaultRef.recordBalance();
        if (rewardsDelta != 0) {
            _accountingState.cumulativeRewards += rewardsDelta;
        }
        emit RewardsDelta(rewardsDelta);

        _pullRewardsVaultFunds();

        return rewardsDelta;
    }

    function _pullRewardsVaultFunds() internal returns (uint256 pulledAmount) {
        IRewardsVault rewardsVaultRef = _modules.rewardsVault;
        uint256 rewardsVaultBalance = rewardsVaultRef.balance();

        // Slither: zero guard only; no timestamp usage.
        // slither-disable-next-line timestamp,incorrect-equality
        if (rewardsVaultBalance == 0) {
            return 0;
        }

        // slither-disable-next-line reentrancy-benign - rewardsVault is trusted; rebalance is nonReentrant
        rewardsVaultRef.withdrawToCore();
        _accountingState.bufferedAssets += rewardsVaultBalance;
        _accountingState.rewardsVaultBalance = 0;
        emit RewardsVaultFundsPulled(rewardsVaultBalance);
        return rewardsVaultBalance;
    }

    /// @notice Pulls unstaked funds from the staking manager.
    /// @return receivedAmount The amount of unstaked funds received.
    /// @return hasRemainingExits True if there are still attesters in exiting state.
    function _pullUnstakedFunds() internal returns (uint256 receivedAmount, bool hasRemainingExits) {
        IERC20 assetRef = _modules.asset;
        uint256 balanceBefore = assetRef.balanceOf(address(this));

        // Slither: stakingManager is trusted; rebalance is nonReentrant and role-gated.
        // slither-disable-next-line reentrancy-benign
        (receivedAmount, hasRemainingExits) = _modules.stakingManager.getUnstakedFunds();

        uint256 balanceAfter = assetRef.balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;

        if (receivedAmount != 0 && receivedAmount != actualReceived) {
            revert OllaCore__UnstakedFundsMismatch(receivedAmount, actualReceived);
        }

        if (actualReceived > 0) {
            _accountingState.bufferedAssets += actualReceived;
            emit UnstakedFundsClaimed(actualReceived);
        }

        return (actualReceived, hasRemainingExits);
    }

    // Slither: external calls under nonReentrant entrypoints; module is trusted.
    // slither-disable-next-line reentrancy-benign
    // solhint-disable function-max-lines
    /// @notice Finalizes pending withdrawal requests using available liquidity.
    /// @return finalizedAmount The amount of assets used to finalize withdrawals.
    function _finalizeWithdrawals() internal returns (uint256 finalizedAmount) {
        // Requires the caller to have reconciled buffered assets (rebalance does this via _syncBufferedWithBalance).
        uint256 bufferedAssets = _accountingState.bufferedAssets;
        uint256 availableForWithdrawals = bufferedAssets;

        // Slither: zero guard only; no timestamp usage.
        // slither-disable-next-line timestamp,incorrect-equality
        if (availableForWithdrawals == 0) {
            return 0;
        }
        IOllaCore.Modules memory modules = _modules;
        uint256 queued = modules.withdrawalQueue.totalPendingAssets();
        uint256 total = totalAssets();

        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign - external calls under nonReentrant entrypoints
        ISafetyModule(modules.safetyModule).checkQueueRatio(queued, total);

        // Slither: zero guard only; no timestamp usage.
        // slither-disable-next-line timestamp,incorrect-equality
        if (queued == 0) {
            return 0;
        }

        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign - external call under nonReentrant entrypoints
        uint256 finalizedCount;
        (finalizedAmount, finalizedCount) = modules.withdrawalQueue.finalizeWithdrawals(availableForWithdrawals);

        uint256 queuedAfter = modules.withdrawalQueue.totalPendingAssets();
        if (queued - queuedAfter != finalizedAmount) {
            revert OllaCore__FinalizeAmountMismatch(queued - queuedAfter, finalizedAmount);
        }

        if (finalizedAmount > bufferedAssets) {
            revert OllaCore__InsufficientBucketBalance(Bucket.Buffered, finalizedAmount, bufferedAssets);
        }

        // Slither: zero guard only.
        // slither-disable-next-line incorrect-equality
        if ((finalizedAmount == 0) != (finalizedCount == 0)) {
            revert OllaCore__FinalizeInconsistent(finalizedAmount, finalizedCount);
        }

        // Slither: zero guard only.
        // slither-disable-next-line incorrect-equality
        if (finalizedAmount == 0) {
            return 0;
        }

        _decreaseBuffered(finalizedAmount);
        _finalizedUnclaimedAssets += finalizedAmount;

        emit WithdrawalFinalized(availableForWithdrawals, finalizedAmount);
        return finalizedAmount;
    }

    // solhint-enable function-max-lines

    // Slither: internal helper, not an initializer.
    // slither-disable-start pess-unprotected-initialize
    /// @notice Initiates unstaking for a bounded amount.
    /// @param requested The remaining amount to initiate for unstake.
    /// @return initiated Amount actually initiated for unstake.
    function _initiateUnstake(uint256 requested) internal returns (uint256 initiated) {
        // Slither: zero guard only; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (requested == 0) {
            return 0;
        }

        IOllaCore.Modules memory modules = _modules;
        uint256 pendingUnstakes = modules.stakingManager.pendingUnstakes();

        // Slither: internal rebalance state machine; trusted module call under nonReentrant entrypoint.
        // slither-disable-next-line reentrancy-no-eth
        initiated = modules.stakingManager.unstake(requested);
        // Slither: explicit nonzero check; no timestamp usage.
        // slither-disable-next-line timestamp
        if (initiated > 0) {
            emit UnstakeInitiated(requested + pendingUnstakes, initiated);
        }
        return initiated;
    }

    // slither-disable-end pess-unprotected-initialize

    // slither-disable-start pess-multiple-storage-read
    /// @notice Stakes surplus buffered assets above the required buffer.
    /// @param stakeable The amount to attempt staking.
    /// @return totalStaked The total amount staked during this operation.
    function _stakeSurplus(uint256 stakeable) internal returns (uint256 totalStaked) {
        // Slither: zero guard only; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (stakeable == 0) {
            return 0;
        }

        IOllaCore.AccountingState memory accountingSnapshot = _accountingState;
        uint256 bufferedAssets = accountingSnapshot.bufferedAssets;
        uint256 stakedPrincipal = accountingSnapshot.stakedPrincipal;

        IERC20 assetRef = _modules.asset;
        IStakingManager stakingManagerRef = _modules.stakingManager;

        assetRef.forceApprove(address(stakingManagerRef), stakeable);
        // Slither: rebalance is nonReentrant and stakingManager is a trusted module.
        // slither-disable-next-line reentrancy-no-eth
        try stakingManagerRef.stake(stakeable) returns (uint256 actualStaked) {
            // Slither: bounds check only; no timestamp usage.
            // slither-disable-next-line timestamp
            if (actualStaked > stakeable) {
                revert OllaCore__StakeFailed(actualStaked);
            }
            totalStaked = actualStaked;
        } catch {
            revert OllaCore__StakeFailed(stakeable);
        }

        // Slither: explicit nonzero check; no timestamp usage.
        // slither-disable-next-line timestamp
        if (totalStaked > 0) {
            _accountingState.bufferedAssets = bufferedAssets - totalStaked;
            _accountingState.stakedPrincipal = stakedPrincipal + totalStaked;
        }

        return totalStaked;
    }
    // slither-disable-end pess-multiple-storage-read

    function _requestRedeem(address owner, uint256 shares, address recipient) internal returns (uint256 requestId) {
        if (recipient == address(0)) {
            revert OllaCore__ZeroAddress("recipient");
        }
        if (shares == 0) {
            revert OllaCore__InvalidAmount();
        }

        Modules memory modules = _modules;

        uint256 rate = _exchangeRate();
        uint256 assetsExpected = _convertToAssets(shares);
        ISafetyModule(modules.safetyModule).checkWithdrawalMinimum(shares);
        uint256 expectedRequestId = modules.withdrawalQueue.nextRequestId();

        _requestOwners[expectedRequestId] = owner;
        _ownerRequestIndex[expectedRequestId] = _ownerRequestIds[owner].length + 1;
        _ownerRequestIds[owner].push(expectedRequestId);
        _increaseCumulativeWithdrawals(assetsExpected);
        modules.stAztec.burn(owner, shares);

        requestId = modules.withdrawalQueue.requestWithdrawal(recipient, shares, assetsExpected, rate);
        // Slither: false positive — comparing request IDs, not timestamps.
        // slither-disable-next-line timestamp
        if (requestId != expectedRequestId) {
            revert OllaCore__UnexpectedRequestId(expectedRequestId, requestId);
        }

        emit WithdrawalRequested(requestId, owner, recipient, shares, assetsExpected, rate);
        return requestId;
    }

    /// @notice Internal instant redemption logic.
    /// @param owner The share owner being redeemed from.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the net assets after fee.
    /// @return netAssets The net assets transferred to the recipient.
    function _redeem(address owner, uint256 shares, address recipient) internal returns (uint256 netAssets) {
        if (recipient == address(0)) {
            revert OllaCore__ZeroAddress("recipient");
        }
        if (shares == 0) {
            revert OllaCore__InvalidAmount();
        }

        Modules memory modules = _modules;

        // Safety module pause check — instant redemptions directly impact protocol liquidity
        if (ISafetyModule(modules.safetyModule).isPaused()) {
            revert OllaCore__SafetyModulePaused();
        }

        _syncBufferedWithBalance();

        ISafetyModule(modules.safetyModule).checkWithdrawalMinimum(shares);

        // Compute exchange rate and asset amounts
        uint256 rate = _exchangeRate();
        uint256 grossAssets = _convertToAssets(shares);
        uint256 fee = grossAssets * instantRedemptionFeeBP / BP_DIVISOR;
        netAssets = grossAssets - fee;

        // Check liquidity — bufferedAssets already excludes _finalizedUnclaimedAssets after sync
        uint256 available = availableForInstantRedemption();
        // Slither: timestamp warning is a false positive; this is a liquidity guard, not a timestamp check.
        // slither-disable-next-line timestamp
        if (grossAssets > available) {
            revert OllaCore__InsufficientLiquidity(grossAssets, available);
        }

        // Burn shares from owner
        // Slither: stAztec is a trusted protocol-owned contract with no callback hooks;
        // external entry points (redeem, redeemWithPermit) are nonReentrant.
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
        modules.stAztec.burn(owner, shares);

        // Decrease buffered assets by grossAssets (fee + net)
        _decreaseBuffered(grossAssets);

        // Transfer net assets to recipient
        modules.asset.safeTransfer(recipient, netAssets);

        // Transfer fee to treasury (governance)
        // slither-disable-next-line incorrect-equality
        if (fee != 0) {
            modules.asset.safeTransfer(modules.governance, fee);
        }

        // Track in flow counters and reset idle buffer
        _increaseCumulativeWithdrawals(grossAssets);

        emit InstantRedemption(owner, recipient, shares, grossAssets, fee, netAssets, rate);
        return netAssets;
    }

    /// @notice Payout protocol fees through minting shares.
    /// @param grossAssetRewards The gross asset rewards to charge fees on.
    /// @return ollaProtocolFeeAssets The asset amount paid as protocol fees.
    /// @return treasuryShares The shares minted to the treasury.
    /// @return providerShares The shares minted to the provider.
    function _payoutOllaProtocolFees(uint256 grossAssetRewards)
        internal
        returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        // Slither: zero guard only; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (grossAssetRewards == 0 || protocolFeeBP == 0 || totalAssets() == 0) {
            return (0, 0, 0);
        }
        Modules memory modules = _modules;
        (ollaProtocolFeeAssets, treasuryShares, providerShares) = _calculateProtocolFees(grossAssetRewards);
        emit OllaProtocolFeesPaid(ollaProtocolFeeAssets, treasuryShares, providerShares);
        modules.stAztec.mint(modules.governance, treasuryShares);
        address providerRewardsRecipient = modules.stakingManager.getProviderConfig().rewardsRecipient;
        modules.stAztec.mint(providerRewardsRecipient, providerShares);

        return (ollaProtocolFeeAssets, treasuryShares, providerShares);
    }

    // Slither: external calls under nonReentrant entrypoints; module is trusted.
    // slither-disable-next-line reentrancy-benign
    function _claimWithdrawal(uint256 requestId) internal returns (uint256 assets) {
        IWithdrawalQueue queue = _modules.withdrawalQueue;
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        address receiver = request.recipient;
        assets = request.assetsExpected;
        address owner = _requestOwners[requestId];

        _removeOwnerRequest(owner, requestId);
        delete _requestOwners[requestId];

        uint256 assetsClaimed = queue.claimWithdrawal(requestId);
        if (assetsClaimed != assets) {
            revert OllaCore__ClaimAssetsMismatch(requestId, assets, assetsClaimed);
        }

        if (request.finalized) {
            _finalizedUnclaimedAssets -= assets;
        }
        _modules.asset.safeTransfer(receiver, assets);
        emit WithdrawalClaimed(requestId, receiver, assets);
        return assets;
    }

    function _removeOwnerRequest(address owner, uint256 requestId) internal {
        uint256 index = _ownerRequestIndex[requestId];
        if (index == 0) {
            revert OllaCore__RequestNotFound(requestId);
        }

        uint256[] storage requestIds = _ownerRequestIds[owner];
        uint256 lastIndex = requestIds.length;
        uint256 removeIndex = index - 1;

        if (removeIndex != lastIndex - 1) {
            uint256 lastRequestId = requestIds[lastIndex - 1];
            requestIds[removeIndex] = lastRequestId;
            _ownerRequestIndex[lastRequestId] = index;
        }

        requestIds.pop();
        delete _ownerRequestIndex[requestId];
    }

    function _increaseCumulativeDeposits(uint256 amount) internal {
        _flowCounters.cumulativeDeposits += amount;
        _rebalanceIdleBuffer = 0;
    }

    function _increaseCumulativeWithdrawals(uint256 amount) internal {
        _flowCounters.cumulativeWithdrawals += amount;
        _rebalanceIdleBuffer = 0;
    }

    // Slither: using storage refs is clearer for snapshot update.
    // slither-disable-next-line pess-multiple-storage-read
    function _updateReportingSnapshots(
        uint256 total,
        uint256 rate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 updatedCumulativeDeposits,
        uint256 updatedCumulativeWithdrawals,
        uint256 rewardsSnapshot
    ) internal {
        IOllaCore.LatestReport storage report = _latestReport;
        report.totalAssets = total;
        report.exchangeRate = rate;
        report.grossRewards = grossRewards;
        report.netFlows = netFlows;
        report.rewardsSnapshot = rewardsSnapshot;

        // Timestamp is used only for reporting/accounting liveness.
        // slither-disable-next-line timestamp
        report.timestamp = block.timestamp;

        IOllaCore.FlowCounters storage flows = _flowCounters;
        flows.latestReportCumulativeDeposits = updatedCumulativeDeposits;
        flows.latestReportCumulativeWithdrawals = updatedCumulativeWithdrawals;
    }

    // Slither: storage updates are grouped for clarity.
    // slither-disable-next-line pess-multiple-storage-read
    function _applyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsVaultBalance,
        uint256 newClaimableRewards,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) internal {
        IOllaCore.AccountingState storage stateSnapshot = _accountingState;
        stateSnapshot.stakedPrincipal = newStakedPrincipal;
        stateSnapshot.rewardsVaultBalance = newRewardsVaultBalance;
        stateSnapshot.claimableRewards = newClaimableRewards;
        stateSnapshot.rewardsDelta = newRewardsDelta;
        stateSnapshot.slashingDelta = newSlashingDelta;
    }

    function _increaseBuffered(uint256 amount) internal {
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        uint256 oldValue = _accountingState.bufferedAssets;
        uint256 newValue = oldValue + amount;
        _accountingState.bufferedAssets = newValue;
    }

    function _decreaseBuffered(uint256 amount) internal {
        // Slither: zero guard only; no timestamp usage.
        // slither-disable-next-line timestamp,incorrect-equality
        if (amount == 0) {
            revert OllaCore__InvalidAmount();
        }
        _accountingState.bufferedAssets -= amount;
    }

    function _computeAndFinalizeAccounting(
        ISafetyModule safetyModuleRef,
        IOllaCore.FlowCounters memory flowsSnapshot,
        int256 netFlows,
        uint256 currentRewards
    ) internal {
        (uint256 oldTotalAssets, uint256 oldRate) = _getLatestReport();
        // Slither: external calls (stAztec mint + safety module) are trusted and guarded by nonReentrant entrypoints.
        // slither-disable-next-line reentrancy-no-eth
        // slither-disable-next-line reentrancy-benign
        (
            IOllaCore.AccountingState memory updatedBuckets,
            uint256 newTotalAssets,
            uint256 grossRewards,
            uint256 protocolFeeAssets,
            uint256 treasuryShares,
            uint256 providerShares,
            uint256 rate
        ) = _computeAccountingOutputs(oldTotalAssets, netFlows);

        IOllaCore.Modules memory modules = _modules;
        uint256 queued = modules.withdrawalQueue.totalPendingAssets();
        // slither-disable-next-line reentrancy-no-eth
        safetyModuleRef.checkQueueRatio(queued, newTotalAssets);
        _validateRateDrop(safetyModuleRef, oldRate, rate);
        _updateReportingSnapshots(
            newTotalAssets,
            rate,
            grossRewards,
            netFlows,
            flowsSnapshot.cumulativeDeposits,
            flowsSnapshot.cumulativeWithdrawals,
            currentRewards
        );
        _updateAccountingTimestamp(safetyModuleRef);
        _emitAccountingReport(
            updatedBuckets,
            newTotalAssets,
            rate,
            grossRewards,
            netFlows,
            protocolFeeAssets,
            treasuryShares,
            providerShares
        );
    }

    function _computeAccountingOutputs(uint256 oldTotalAssets, int256 netFlows)
        internal
        returns (
            IOllaCore.AccountingState memory updatedBuckets,
            uint256 newTotalAssets,
            uint256 grossRewards,
            uint256 protocolFeeAssets,
            uint256 treasuryShares,
            uint256 providerShares,
            uint256 rate
        )
    {
        updatedBuckets = _accountingState;
        newTotalAssets = _computeTotalAssets(updatedBuckets);
        int256 grossRewardsSigned;
        (grossRewards, grossRewardsSigned) = _computeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        // slither-disable-next-line timestamp
        if (grossRewardsSigned < 0) {
            emit NegativeRewardsPeriod(grossRewardsSigned);
        }
        (protocolFeeAssets, treasuryShares, providerShares) = _payoutOllaProtocolFees(grossRewards);
        rate = _exchangeRate();
        return (updatedBuckets, newTotalAssets, grossRewards, protocolFeeAssets, treasuryShares, providerShares, rate);
    }

    function _validateRateDrop(ISafetyModule safetyModuleRef, uint256 oldRate, uint256 rate) internal {
        safetyModuleRef.checkRateDrop(oldRate, rate);
    }

    function _updateAccountingTimestamp(ISafetyModule safetyModuleRef) internal {
        // Timestamp is used only for reporting/accounting liveness.
        // slither-disable-next-line timestamp
        safetyModuleRef.setLatestAccountingTimestamp(block.timestamp);
    }

    function _emitAccountingReport(
        IOllaCore.AccountingState memory updatedBuckets,
        uint256 newTotalAssets,
        uint256 rate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares
    ) internal {
        emit AttestersStateRead(updatedBuckets.rewardsDelta, updatedBuckets.slashingDelta, _latestReport.timestamp);
        emit AccountingUpdated(
            newTotalAssets,
            rate,
            grossRewards,
            netFlows,
            protocolFeeAssets,
            treasuryShares,
            providerShares,
            _latestReport.timestamp
        );
    }

    /// @dev Tokens sent directly to OllaCore are absorbed as donations benefiting all stAztec holders
    ///      proportionally. Any surplus (actual balance minus bufferedAssets minus finalizedUnclaimed) is
    ///      added to bufferedAssets. This is intentional and irreversible — the virtual offset (+1) pattern
    ///      in the conversion functions prevents this from being exploitable for share price manipulation.
    function _reconcileBufferedAssets(address recipient) internal returns (uint256 delta) {
        uint256 buffered = _accountingState.bufferedAssets;
        uint256 actual = _modules.asset.balanceOf(address(this));
        if (actual < _finalizedUnclaimedAssets) {
            revert OllaCore__BufferedBalanceMismatch(buffered, actual);
        }
        uint256 available = actual - _finalizedUnclaimedAssets;
        // slither-disable-next-line timestamp
        if (available < buffered) {
            revert OllaCore__BufferedBalanceMismatch(buffered, available);
        }
        delta = available - buffered;
        if (delta != 0) {
            _accountingState.bufferedAssets = available;
            emit BufferedAssetsReconciled(delta, available, recipient);
        }
        return delta;
    }

    function _syncBufferedWithBalance() internal {
        _reconcileBufferedAssets(address(this));
    }

    function _getStakingManagerState()
        internal
        view
        returns (
            uint256 currentRewards,
            uint256 rewardsDelta,
            uint256 slashingDelta,
            uint256 stakedPrincipal,
            uint256 claimableRewards
        )
    {
        IOllaCore.Modules memory modules = _modules;
        IOllaCore.AccountingState memory accountingSnapshot = _accountingState;
        claimableRewards = modules.stakingManager.getClaimableRewards();
        currentRewards = accountingSnapshot.cumulativeRewards + claimableRewards;

        uint256 latestReportRewards = _latestReport.rewardsSnapshot;

        // Clamp signed delta; no timestamp-based control flow.
        // slither-disable-next-line timestamp
        int256 rewardsDeltaSigned = SafeCast.toInt256(currentRewards) - SafeCast.toInt256(latestReportRewards);

        // slither-disable-next-line timestamp
        // Defensive: currentRewards should be non-decreasing, but clamp if a downstream module reports a drop.
        // slither-disable-next-line timestamp
        if (rewardsDeltaSigned > 0) {
            rewardsDelta = SafeCast.toUint256(rewardsDeltaSigned);
        }
        slashingDelta = modules.stakingManager.getSlashingDelta();
        stakedPrincipal = modules.stakingManager.totalStaked();
        return (currentRewards, rewardsDelta, slashingDelta, stakedPrincipal, claimableRewards);
    }

    function _hasGasForStep() internal view returns (bool) {
        return gasleft() > rebalanceGasThreshold;
    }

    /// @notice Checks if external state changes have created new rebalance work.
    /// @dev Only checks for external state changes (rewards vault, claimable rewards,
    ///      unstaked funds, pending withdrawals). Does NOT check staking/unstaking calculations because
    ///      if _rebalanceIdleBuffer is set, the previous cycle already attempted that
    ///      work and couldn't make progress. We only retry when external conditions change.
    /// @return True if new external work is available, false otherwise.
    // Slither: timestamp warning is a false positive; these are zero-guards not timestamp comparisons.
    // slither-disable-next-line timestamp,pess-multiple-storage-read
    function _hasRebalanceWorkAvailable() internal view returns (bool) {
        // Check for rewards vault funds to pull
        uint256 rewardsVaultBalance = _getRewardsVaultBalance();
        if (rewardsVaultBalance > 0) {
            return true;
        }

        // Check for claimable rollup rewards not yet in the rewards vault
        if (_modules.stakingManager.getClaimableRewards() > 0) {
            return true;
        }

        // Check for exitable unstakes that could be pulled
        if (_modules.stakingManager.hasExitableUnstakes()) {
            return true;
        }

        // Check for pending withdrawals that could be finalized
        uint256 pendingWithdrawals = _modules.withdrawalQueue.totalPendingAssets();
        if (pendingWithdrawals > 0 && _accountingState.bufferedAssets > 0) {
            return true;
        }

        return false;
    }

    function _rebalanceCompletionSatisfied(IOllaCore.RebalanceProgress memory progress) internal view returns (bool) {
        // Slither: enum state machine uses explicit equality checks; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (progress.step != IOllaCore.RebalanceStep.Done) {
            return false;
        }
        if (progress.stakeRemaining != 0 || progress.unstakeRemaining != 0) {
            return false;
        }

        uint256 bufferedAssets = _accountingState.bufferedAssets;
        uint256 pending = _modules.withdrawalQueue.totalPendingAssets();
        // Slither: zero guard only; no timestamp usage.
        // slither-disable-next-line incorrect-equality,timestamp
        if (pending != 0 && bufferedAssets != 0) {
            // If there are pending unstakes, keep the pause — unstaked funds will arrive
            // and be pulled in a future cycle to cover the pending withdrawals.
            // If there are no pending unstakes, the rebalance has done all it can —
            // allow completion so the protocol can accept new deposits or process
            // finalization once more buffer arrives.
            uint256 pendingUnstakeAmount = _modules.stakingManager.pendingUnstakes();
            if (pendingUnstakeAmount > 0) {
                return false;
            }
        }

        // The rebalance state machine already ensures that surplus buffer is staked when possible.
        // If StakeSurplus advanced to Done with stakeRemaining=0, it means either all surplus was
        // staked or the staking manager couldn't stake the remainder (e.g. below minimum threshold).
        // No additional surplus buffer check is needed here — the cycle is genuinely complete.
        return true;
    }

    function _computeRequiredBuffer() internal view returns (uint256 requiredBuffer, uint256 pendingWithdrawals) {
        pendingWithdrawals = _modules.withdrawalQueue.totalPendingAssets();
        uint256 targetBuffered = targetBufferedAssets;
        requiredBuffer = pendingWithdrawals + targetBuffered;
        return (requiredBuffer, pendingWithdrawals);
    }

    function _computeUnstakeRemaining(uint256 requiredBuffer) internal view returns (uint256 remaining) {
        uint256 bufferedAssets = _accountingState.bufferedAssets;
        // slither-disable-next-line timestamp
        if (requiredBuffer < bufferedAssets) {
            return 0;
        }
        uint256 amountToUnstake = requiredBuffer - bufferedAssets;
        uint256 pendingUnstakes = _modules.stakingManager.pendingUnstakes();
        // slither-disable-next-line timestamp
        if (pendingUnstakes > amountToUnstake) {
            return 0;
        }
        remaining = amountToUnstake - pendingUnstakes;
        return remaining;
    }

    function _computeStakeRemaining(uint256 requiredBuffer) internal view returns (uint256 remaining) {
        uint256 bufferedAssets = _accountingState.bufferedAssets;
        // slither-disable-next-line timestamp
        if (bufferedAssets < requiredBuffer) {
            return 0;
        }
        remaining = bufferedAssets - requiredBuffer;
        return remaining;
    }

    function _getFlowsSnapshot() internal view returns (IOllaCore.FlowCounters memory flowsSnapshot, int256 netFlows) {
        flowsSnapshot = _flowCounters;
        (netFlows,,) = _computeNetFlows(flowsSnapshot);
        return (flowsSnapshot, netFlows);
    }

    function _getLatestReport() internal view returns (uint256 reportedTotalAssets, uint256 reportedExchangeRate) {
        IOllaCore.LatestReport memory report = _latestReport;
        return (report.totalAssets, report.exchangeRate);
    }

    function _getRewardsVaultBalance() internal view returns (uint256 rewardsVaultBalance) {
        return IRewardsVault(_modules.rewardsVault).balance();
    }

    function _validateSlashingDelta(uint256 slashingDelta) internal view {
        uint256 previousSlashingDelta = _accountingState.slashingDelta;
        // slither-disable-next-line timestamp
        if (slashingDelta < previousSlashingDelta) {
            revert OllaCore__InvalidSlashingDelta(previousSlashingDelta, slashingDelta);
        }
    }

    function _calculateProtocolFees(uint256 grossAssetRewards)
        internal
        view
        returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        ollaProtocolFeeAssets = grossAssetRewards * protocolFeeBP / BP_DIVISOR;

        uint256 protocolSharesTotal = _convertToShares(ollaProtocolFeeAssets, Math.Rounding.Floor);

        treasuryShares = protocolSharesTotal * treasuryFeeSplitBP / BP_DIVISOR;
        providerShares = protocolSharesTotal - treasuryShares;

        return (ollaProtocolFeeAssets, treasuryShares, providerShares);
    }

    /// @dev All share/asset conversion functions use a virtual offset of +1 on both totalAssets and
    ///      totalSupply. This prevents the first-depositor inflation attack (ERC-4626 "donation" attack)
    ///      where an attacker deposits 1 wei, donates a large amount, and exploits rounding to steal from
    ///      the next depositor. The +1 offset ensures the exchange rate is well-defined even when supply
    ///      or assets are zero, and makes the cost of the attack proportional to the offset value.
    ///      See: https://docs.openzeppelin.com/contracts/5.x/erc4626#inflation-attack

    function _exchangeRate() internal view returns (uint256) {
        return (totalAssets() + 1).mulDiv(_EXCHANGE_RATE_SCALE, _modules.stAztec.totalSupply() + 1, Math.Rounding.Floor);
    }

    function _convertToSharesForDeposit(uint256 assets) internal view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, _modules.stAztec.totalSupply() + 1, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(_modules.stAztec.totalSupply() + 1, totalAssets() + 1, rounding);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (msg.sender != _modules.governance) {
            revert OllaCore__UnauthorizedGovernance(msg.sender);
        }
        if (newImplementation == address(0)) {
            revert OllaCore__ZeroAddress("newImplementation");
        }
    }

    function _validateInitialParams(
        IERC20 asset_,
        IStAztec stAztec_,
        IStakingManager stakingManager_,
        uint256 protocolFeeBP_,
        uint256 treasuryFeeSplitBP_,
        address governance_,
        address withdrawalQueue_,
        IRewardsVault rewardsVault_,
        address safetyModule_
    ) internal pure {
        if (address(asset_) == address(0)) {
            revert OllaCore__ZeroAddress("asset_");
        }
        if (address(stAztec_) == address(0)) {
            revert OllaCore__ZeroAddress("stAztec_");
        }
        if (address(stakingManager_) == address(0)) {
            revert OllaCore__ZeroAddress("stakingManager_");
        }
        if (protocolFeeBP_ > MAX_PROTOCOL_FEE_BP) {
            revert OllaCore__InvalidFeeBP(protocolFeeBP_);
        }
        if (treasuryFeeSplitBP_ < MIN_TREASURY_SPLIT_BP || treasuryFeeSplitBP_ > MAX_TREASURY_SPLIT_BP) {
            revert OllaCore__InvalidSplitBP(treasuryFeeSplitBP_);
        }
        if (governance_ == address(0)) {
            revert OllaCore__ZeroAddress("governance_");
        }
        if (withdrawalQueue_ == address(0)) {
            revert OllaCore__ZeroAddress("withdrawalQueue_");
        }
        if (address(rewardsVault_) == address(0)) {
            revert OllaCore__ZeroAddress("rewardsVault_");
        }
        if (safetyModule_ == address(0)) {
            revert OllaCore__ZeroAddress("safetyModule_");
        }
    }

    function _computeNetFlows(IOllaCore.FlowCounters memory flows)
        internal
        pure
        returns (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        // Slither: false positive — comparing cumulative flow counters, not timestamps.
        // slither-disable-next-line timestamp
        netDeposits = flows.cumulativeDeposits > flows.latestReportCumulativeDeposits
            ? flows.cumulativeDeposits - flows.latestReportCumulativeDeposits
            : 0;
        // slither-disable-next-line timestamp
        netWithdrawals = flows.cumulativeWithdrawals > flows.latestReportCumulativeWithdrawals
            ? flows.cumulativeWithdrawals - flows.latestReportCumulativeWithdrawals
            : 0;
        netFlows = SafeCast.toInt256(netDeposits) - SafeCast.toInt256(netWithdrawals);
        return (netFlows, netDeposits, netWithdrawals);
    }

    function _computeTotalAssets(IOllaCore.AccountingState memory buckets)
        internal
        pure
        returns (uint256 totalAssets_)
    {
        uint256 total =
            buckets.bufferedAssets + buckets.stakedPrincipal + buckets.rewardsVaultBalance + buckets.claimableRewards;
        // Slither: false positive — comparing asset amounts, not timestamps.
        // slither-disable-next-line timestamp
        totalAssets_ = buckets.slashingDelta >= total ? 0 : total - buckets.slashingDelta;
        return totalAssets_;
    }

    function _computeGrossRewards(uint256 oldTotalAssets, uint256 newTotalAssets, int256 netFlows)
        internal
        pure
        returns (uint256 grossRewards, int256 grossRewardsSigned)
    {
        int256 changeInAssets = SafeCast.toInt256(newTotalAssets) - SafeCast.toInt256(oldTotalAssets);
        // Clamp signed delta; no timestamp-based control flow.
        // slither-disable-next-line timestamp
        grossRewardsSigned = changeInAssets - netFlows;
        // slither-disable-next-line timestamp
        if (grossRewardsSigned > 0) {
            grossRewards = SafeCast.toUint256(grossRewardsSigned);
        }
        return (grossRewards, grossRewardsSigned);
    }
}
