// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";

/// @title IOllaVault
/// @notice Interface for the user-facing ERC-7540/ERC-7575/ERC-4626 vault.
/// @dev Holds assets, mints/burns stAztec, manages withdrawal requests,
///      and delegates pricing to OllaCore via cross-contract view calls.
/// @author Olla Core contributors
interface IOllaVault {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct VaultModules {
        IERC20 asset;
        IStAztec stAztec;
        IWithdrawalQueue withdrawalQueue;
        address core;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // solhint-disable gas-indexed-events
    /// @notice Emitted when a deposit is completed.
    /// @param caller The address that initiated the deposit.
    /// @param recipient The address receiving the shares.
    /// @param assets The assets deposited.
    /// @param shares The shares minted.
    event Deposit(address indexed caller, address indexed recipient, uint256 assets, uint256 shares);

    /// @notice Emitted when a withdrawal request is created.
    /// @param requestId The withdrawal request id.
    /// @param owner The share owner that initiated the request.
    /// @param recipient The address receiving the assets.
    /// @param shares The shares burned.
    /// @param assetsExpected The assets expected at request time.
    /// @param exchangeRate The exchange rate locked at request time.
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256 shares,
        uint256 assetsExpected,
        uint256 exchangeRate
    );

    /// @notice Emitted when a withdrawal is claimed via queue.
    /// @param requestId Withdrawal request id.
    /// @param recipient Recipient address.
    /// @param assets Assets claimed.
    event WithdrawalClaimed(uint256 requestId, address recipient, uint256 assets);

    /// @notice Emitted when withdrawals are finalized.
    /// @param available Available assets.
    /// @param used Used assets.
    event WithdrawalFinalized(uint256 available, uint256 used);

    /// @notice Emitted when an instant redemption is completed.
    /// @param owner The share owner.
    /// @param recipient The address receiving the net assets.
    /// @param shares The shares burned.
    /// @param grossAssets The total assets before fee.
    /// @param fee The fee deducted and sent to treasury.
    /// @param netAssets The net assets transferred to the recipient.
    /// @param exchangeRate The exchange rate used.
    event InstantRedemption(
        address indexed owner,
        address indexed recipient,
        uint256 shares,
        uint256 grossAssets,
        uint256 fee,
        uint256 netAssets,
        uint256 exchangeRate
    );

    /// @notice Emitted when the instant redemption fee is updated.
    /// @param oldFeeBP The previous fee in basis points.
    /// @param newFeeBP The new fee in basis points.
    event InstantRedemptionFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);

    /// @notice Emitted when an operator is set or removed for a controller (ERC-7540).
    /// @param controller The address of the controller.
    /// @param operator The address of the operator.
    /// @param approved The approval status.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Emitted when an async redeem request is submitted (ERC-7540).
    /// @param controller The controller of the request.
    /// @param owner The source of the shares.
    /// @param requestId The withdrawal request id.
    /// @param sender The address that submitted the request.
    /// @param assets The expected assets at request time.
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    /// @notice Emitted when buffered assets are reconciled with the actual balance.
    /// @param delta The amount added to buffered assets.
    /// @param newBufferedAssets The updated buffered assets amount.
    /// @param recipient The recipient that benefits from reconciliation.
    event BufferedAssetsReconciled(uint256 delta, uint256 newBufferedAssets, address indexed recipient);

    /// @notice Emitted when stAztec is recovered from the vault.
    /// @param amount The amount recovered.
    /// @param recipient The recipient of the recovered stAztec.
    event StAztecRecovered(uint256 amount, address indexed recipient);

    /// @notice Emitted when assets are transferred to staking.
    /// @param amount The amount transferred.
    event AssetsTransferredToStaking(uint256 amount);

    /// @notice Emitted when unstaked assets are received by the vault.
    /// @param amount The amount received.
    event UnstakedAssetsReceived(uint256 amount);

    /// @notice Emitted when fee shares are minted.
    /// @param treasuryShares Shares minted to treasury.
    /// @param providerShares Shares minted to provider.
    event FeesMinted(uint256 treasuryShares, uint256 providerShares);

    // solhint-enable gas-indexed-events

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a zero address is provided.
    error OllaVault__ZeroAddress(string param);

    /// @notice Thrown when queue request ids are inconsistent.
    error OllaVault__UnexpectedRequestId(uint256 expected, uint256 actual);

    /// @notice Thrown when a deposit exceeds the configured cap.
    error OllaVault__DepositCapExceeded(uint256 assets, uint256 totalAssets);

    /// @notice Thrown when deposits are blocked by the safety module pause.
    error OllaVault__SafetyModulePaused();

    /// @notice Thrown when an amount is zero or otherwise invalid.
    error OllaVault__InvalidAmount();

    /// @notice Thrown when a fee basis points value exceeds maximum.
    error OllaVault__InvalidFeeBP(uint256 feeBP);

    /// @notice Thrown when an instant redemption exceeds available liquidity.
    error OllaVault__InsufficientLiquidity(uint256 requested, uint256 available);

    /// @notice Thrown when output is less than the caller's minimum.
    error OllaVault__SlippageExceeded(uint256 actual, uint256 minimum);

    /// @notice Thrown when a request is not found in the owner's index.
    error OllaVault__RequestNotFound(uint256 requestId);

    /// @notice Thrown when the caller is not the controller or an approved operator.
    error OllaVault__Unauthorized();

    /// @notice Thrown when a function is not supported (e.g., sync operations on async vault).
    error OllaVault__NotSupported();

    /// @notice Thrown when a parameter is invalid.
    error OllaVault__InvalidParameter();

    /// @notice Thrown when buffered assets do not match the vault balance.
    error OllaVault__BufferedBalanceMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when claimed assets don't match expected.
    error OllaVault__ClaimAssetsMismatch(uint256 requestId, uint256 expected, uint256 actual);

    /// @notice Thrown when vault has insufficient buffer for a transfer.
    error OllaVault__InsufficientBuffer(uint256 requested, uint256 available);

    /// @notice Thrown when previewed and finalized amounts mismatch.
    error OllaVault__FinalizeAmountMismatch(uint256 previewed, uint256 finalized);

    /// @notice Thrown when finalized amounts are inconsistent with count.
    error OllaVault__FinalizeInconsistent(uint256 finalizedAmount, uint256 finalizedCount);

    /// @notice Thrown when a finalization exceeds available buffered assets.
    error OllaVault__InsufficientBufferedAssets(uint256 amount, uint256 available);

    /// @notice Thrown when claiming a withdrawal request that is not yet finalized.
    error OllaVault__NotFinalized(uint256 requestId);

    /// @notice Thrown when an ERC-20 permit call fails (expired deadline, invalid signature, etc.).
    error OllaVault__PermitFailed(bytes reason);

    /*//////////////////////////////////////////////////////////////
                              CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the vault.
    /// @param asset_ The underlying Aztec asset.
    /// @param stAztec_ The stAztec share token.
    /// @param withdrawalQueue_ The withdrawal queue module address.
    /// @param core_ The OllaCore contract address (for pricing and safetyModule).
    /// @param governanceContract_ The OllaGovernance contract address (set as owner).
    function initialize(
        IERC20 asset_,
        IStAztec stAztec_,
        address withdrawalQueue_,
        address core_,
        address governanceContract_
    ) external;

    /// @notice Deposits assets and mints stAztec shares (Olla-native with slippage).
    /// @param assets The amount of assets to deposit.
    /// @param recipient The recipient of the stAztec shares.
    /// @param minSharesOut The minimum shares the caller expects; set 0 to skip the check.
    /// @return shares The shares minted to the recipient.
    function deposit(uint256 assets, address recipient, uint256 minSharesOut) external returns (uint256 shares);

    /// @notice Deposits assets with a permit signature.
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
    ) external returns (uint256 shares);

    /// @notice Requests async redemption with permit (ERC-7540 semantics).
    /// @param shares The number of shares to redeem from msg.sender.
    /// @param controller The controller of the request who receives the assets.
    /// @param deadline The permit deadline timestamp.
    /// @param v The permit signature v.
    /// @param r The permit signature r.
    /// @param s The permit signature s.
    /// @return requestId The withdrawal request id.
    function requestRedeemWithPermit(
        uint256 shares,
        address controller,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 requestId);

    /// @notice Claims a finalized withdrawal request by id.
    /// @param requestId The withdrawal request id.
    /// @return assets The assets claimed for the request.
    function claimRequestById(uint256 requestId) external returns (uint256 assets);

    /// @notice Instant redemption with fee.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the net assets.
    /// @param minAssetsOut The minimum net assets the caller expects; set 0 to skip the check.
    /// @return assetsAfterFee The net assets transferred to the recipient.
    function instantRedeem(uint256 shares, address recipient, uint256 minAssetsOut)
        external
        returns (uint256 assetsAfterFee);

    /// @notice Instant redemption with permit.
    /// @param shares The number of shares to redeem.
    /// @param recipient The recipient of the net assets.
    /// @param minAssetsOut The minimum net assets the caller expects; set 0 to skip the check.
    /// @param deadline The permit deadline timestamp.
    /// @param v The permit signature v.
    /// @param r The permit signature r.
    /// @param s The permit signature s.
    /// @return assetsAfterFee The net assets transferred to the recipient.
    function instantRedeemWithPermit(
        uint256 shares,
        address recipient,
        uint256 minAssetsOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 assetsAfterFee);

    /*//////////////////////////////////////////////////////////////
                        ERC-4626/7575 SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits assets and mints shares (ERC-4626).
    /// @dev This standard overload has NO slippage protection. Prefer the 3-arg
    ///      `deposit(assets, receiver, minSharesOut)` variant for front-run safety.
    /// @param assets The amount of assets to deposit.
    /// @param receiver The recipient of the minted shares.
    /// @return shares The shares minted to the receiver.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Mints exact shares (ERC-4626).
    /// @param shares The exact number of shares to mint.
    /// @param receiver The recipient of the minted shares.
    /// @return assets The assets deposited.
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Withdraw is not supported for async vaults (ERC-7540).
    /// @param assets The amount of assets to withdraw.
    /// @param receiver The recipient of the assets.
    /// @param owner The owner of the shares.
    /// @return shares The shares burned.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Claims a finalized async redeem request (ERC-4626/ERC-7540).
    /// @param shares The number of shares to redeem.
    /// @param receiver The recipient of the assets.
    /// @param controller The controller of the redeem request.
    /// @return assets The assets claimed.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Sets or removes an operator for the caller (ERC-7540).
    /// @param operator The operator address to set.
    /// @param approved Whether the operator is approved.
    /// @return Whether the call succeeded.
    function setOperator(address operator, bool approved) external returns (bool);

    /// @notice Requests an async redemption (ERC-7540 3-arg version).
    /// @param shares The number of shares to redeem.
    /// @param controller The controller of the request who receives the assets.
    /// @param owner The source of the shares.
    /// @return requestId The withdrawal request id.
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /*//////////////////////////////////////////////////////////////
                      CORE_ROLE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfers buffered assets to Core for staking.
    /// @param amount The amount of assets to transfer to Core (msg.sender).
    function transferToCore(uint256 amount) external;

    /// @notice Receives unstaked assets returned from staking.
    /// @param amount The amount of unstaked assets received.
    function receiveUnstaked(uint256 amount) external;

    /// @notice Finalizes pending withdrawal requests using available liquidity.
    /// @param availableAssets Max assets to use for finalization.
    /// @param currentRate The current exchange rate for slashing adjustment.
    /// @return finalizedAmount Actual assets used.
    /// @return finalizedCount Number of requests finalized.
    function finalizeWithdrawals(uint256 availableAssets, uint256 currentRate)
        external
        returns (uint256 finalizedAmount, uint256 finalizedCount);

    /// @notice Mints fee shares to treasury and provider.
    /// @param treasury The treasury address.
    /// @param treasuryShares Shares to mint to treasury.
    /// @param provider The provider rewards recipient address.
    /// @param providerShares Shares to mint to provider.
    function mintFees(address treasury, uint256 treasuryShares, address provider, uint256 providerShares) external;

    /*//////////////////////////////////////////////////////////////
                        GUARDIAN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses the vault.
    function pause() external;

    /// @notice Unpauses the vault.
    function unpause() external;

    /*//////////////////////////////////////////////////////////////
                      GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the instant redemption fee in basis points.
    /// @param newFeeBP The new fee (0-2000).
    function setInstantRedemptionFeeBP(uint256 newFeeBP) external;

    /// @notice Reconciles buffered assets with the actual balance.
    /// @return delta The amount added to buffered assets.
    function reconcileBufferedAssets() external returns (uint256 delta);

    /// @notice Recovers stAztec sent directly to the vault.
    /// @param recipient The recipient of the recovered stAztec (defaults to governance if zero).
    /// @param amount The amount of stAztec to recover.
    function recoverStAztec(address recipient, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                        ERC-4626/7575 VIEW SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the underlying asset address (ERC-4626).
    /// @return The underlying asset address.
    function asset() external view returns (address);

    /// @notice Returns the share token address (ERC-7575).
    /// @return The share token address.
    function share() external view returns (address);

    /// @notice Returns the total assets attributable to shareholders (ERC-4626).
    /// @return The total assets attributable to shareholders.
    function totalAssets() external view returns (uint256);

    /// @notice Converts assets to shares (ERC-4626).
    /// @param assets The amount of assets to convert.
    /// @return The computed share amount.
    function convertToShares(uint256 assets) external view returns (uint256);

    /// @notice Converts shares to assets (ERC-4626).
    /// @param shares The amount of shares to convert.
    /// @return The computed asset amount.
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Returns max depositable assets (ERC-4626).
    /// @return The max depositable assets.
    // solhint-disable-next-line use-natspec
    function maxDeposit(address) external view returns (uint256);

    /// @notice Returns max mintable shares (ERC-4626).
    /// @return The max mintable shares.
    // solhint-disable-next-line use-natspec
    function maxMint(address) external view returns (uint256);

    /// @notice Returns 0 -- withdraw is async (ERC-7540).
    /// @return Always 0 for async vaults.
    // solhint-disable-next-line use-natspec
    function maxWithdraw(address) external view returns (uint256);

    /// @notice Returns total claimable shares for controller (ERC-4626).
    /// @param controller The controller address.
    /// @return The total claimable shares.
    function maxRedeem(address controller) external view returns (uint256);

    /// @notice Returns shares previewed for a deposit (ERC-4626).
    /// @param assets The deposit amount.
    /// @return The shares previewed.
    function previewDeposit(uint256 assets) external view returns (uint256);

    /// @notice Returns assets needed to mint exact shares (ERC-4626).
    /// @param shares The share amount.
    /// @return The assets needed.
    function previewMint(uint256 shares) external view returns (uint256);

    /// @notice Preview withdraw is not supported (ERC-7540).
    /// @param assets The asset amount.
    /// @return Not supported.
    function previewWithdraw(uint256 assets) external view returns (uint256);

    /// @notice Preview redeem is not supported (ERC-7540).
    /// @param shares The share amount.
    /// @return Not supported.
    function previewRedeem(uint256 shares) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                      ERC-7540 OPERATOR + ASYNC VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns claimable (finalized, unclaimed) shares for a request (ERC-7540).
    /// @param requestId The withdrawal request id.
    /// @param controller The controller address.
    /// @return The claimable shares.
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256);

    /// @notice Returns whether an operator is approved for a controller (ERC-7540).
    /// @param controller The controller address.
    /// @param operator The operator address.
    /// @return Whether the operator is approved.
    function isOperator(address controller, address operator) external view returns (bool);

    /// @notice Returns pending (unfinalized) shares for a request (ERC-7540).
    /// @param requestId The withdrawal request id.
    /// @param controller The controller address.
    /// @return The pending shares.
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns current buffered (liquid) assets held by the Vault.
    /// @return The current buffered assets.
    function bufferedAssets() external view returns (uint256);

    /// @notice Returns current pending withdrawal assets.
    /// @return The current pending withdrawal assets.
    function pendingWithdrawalAssets() external view returns (uint256);

    /// @notice Returns current pending withdrawal shares (burned but not yet finalized).
    /// @return The current pending withdrawal shares.
    function pendingWithdrawalShares() external view returns (uint256);

    /// @notice Returns cumulative deposits tracked by the vault.
    /// @return The cumulative deposits.
    function cumulativeDeposits() external view returns (uint256);

    /// @notice Returns cumulative withdrawals tracked by the vault.
    /// @return The cumulative withdrawals.
    function cumulativeWithdrawals() external view returns (uint256);

    /// @notice Returns the withdrawal queue module address.
    /// @return The withdrawal queue address.
    function withdrawalQueue() external view returns (address);

    /// @notice Returns the safety module address (reads canonical reference from Core).
    /// @return The safety module address.
    function safetyModule() external view returns (address);

    /// @notice Returns the OllaCore address.
    /// @return The OllaCore address.
    function core() external view returns (address);

    /// @notice Returns the instant redemption fee in basis points.
    /// @return The instant redemption fee in basis points.
    function instantRedemptionFeeBP() external view returns (uint256);

    /// @notice Returns the maximum assets currently available for instant redemptions.
    /// @return The maximum assets available for instant redemptions.
    function availableForInstantRedemption() external view returns (uint256);

    /// @notice Returns the net assets previewed for an instant redemption.
    /// @param shares The share amount.
    /// @return The net assets previewed.
    function previewInstantRedeem(uint256 shares) external view returns (uint256);

    /// @notice Returns the recorded owner for a withdrawal request id.
    /// @param requestId The request id.
    /// @return owner The recorded owner.
    function requestOwner(uint256 requestId) external view returns (address owner);

    /// @notice Returns the active withdrawal request ids for an owner.
    /// @param owner The owner address.
    /// @return The active request ids.
    function activeRequestIds(address owner) external view returns (uint256[] memory);
}
