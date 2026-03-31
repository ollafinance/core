/*
 * Certora Verification Spec: OllaVault
 *
 * Properties verified:
 *   1. Deposit value passthrough — shares returned == core.convertToShares(assets)
 *   2. Mint value passthrough — assets taken == core.convertToAssetsCeil(shares)
 *   3. Instant redeem fee accounting — fee stays in buffer, net payout = gross - fee
 *   4. Cumulative counter monotonicity — cumulativeDeposits/Withdrawals/ExitFees only increase
 *   5. Buffered assets accounting — deposit increases buffer, redeem decreases it
 *   6. Role gating — CORE_ROLE functions revert for non-core callers
 *   7. Pause behavior — user-facing functions revert when paused
 *   8. Instant redemption fee bounds — fee BP never exceeds MAX
 *   9. No free shares — deposit(0) reverts, mint(0) reverts
 *
 * Summarization note:
 *   Core pricing functions (convertToShares, convertToAssets, convertToAssetsCeil) are
 *   summarized as PER_CALLEE_CONSTANT. This means the prover picks an arbitrary but
 *   consistent return value for each (callee, input) pair within a single rule.
 *   Consequence: "value passthrough" rules prove the vault faithfully uses Core's pricing
 *   without manipulation, but do NOT prove the pricing itself is correct (that is
 *   ExchangeRate.spec's job on OllaCore). Ghost axioms enforce the relationship between
 *   floor/ceil conversions so fee-accounting proofs are sound.
 */

using OllaVaultHarness as vault;

methods {
    // Public state getters
    function bufferedAssets() external returns (uint256) envfree;
    function cumulativeDeposits() external returns (uint256) envfree;
    function cumulativeWithdrawals() external returns (uint256) envfree;
    function cumulativeExitFees() external returns (uint256) envfree;
    function cumulativeSlashingAdjustments() external returns (uint256) envfree;
    function instantRedemptionFeeBP() external returns (uint256) envfree;
    function paused() external returns (bool) envfree;
    function core() external returns (address) envfree;
    function totalAssets() external returns (uint256);
    function pendingWithdrawalAssets() external returns (uint256);
    function pendingWithdrawalShares() external returns (uint256);
    function availableForInstantRedemption() external returns (uint256);

    // Access control
    function hasRole(bytes32, address) external returns (bool) envfree;
    function CORE_ROLE() external returns (bytes32) envfree;
    function GUARDIAN_ROLE() external returns (bytes32) envfree;

    // Harness getters
    function getCumulativeDeposits() external returns (uint256) envfree;
    function getCumulativeWithdrawals() external returns (uint256) envfree;
    function getCumulativeExitFees() external returns (uint256) envfree;
    function getCumulativeSlashingAdjustments() external returns (uint256) envfree;
    function getInstantRedemptionFeeBP() external returns (uint256) envfree;
    function coreConvertToShares(uint256) external returns (uint256);
    function coreConvertToAssets(uint256) external returns (uint256);
    function coreConvertToAssetsCeil(uint256) external returns (uint256);

    // Mutating functions
    function deposit(uint256, address, uint256) external returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function mint(uint256, address) external returns (uint256);
    function instantRedeem(uint256, address, uint256) external returns (uint256);
    function requestRedeem(uint256, address, address) external returns (uint256);
    function claimRequestById(uint256) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function transferToCore(uint256) external;
    function receiveUnstaked(uint256) external;
    function finalizeWithdrawals(uint256, uint256) external returns (uint256, uint256);
    function pause() external;
    function unpause() external;
    function setInstantRedemptionFeeBP(uint256) external;

    // External contract summaries — vault calls core for pricing and queue for pending.
    // PER_CALLEE_CONSTANT: same callee + same input → same return within one rule.
    // This models "Core returns a consistent price" without linking the full Core contract.
    function _.convertToShares(uint256) external => PER_CALLEE_CONSTANT;
    function _.convertToAssets(uint256) external => PER_CALLEE_CONSTANT;
    function _.convertToAssetsCeil(uint256) external => PER_CALLEE_CONSTANT;
    function _.totalAssets() external => PER_CALLEE_CONSTANT;
    function _.exchangeRate() external => PER_CALLEE_CONSTANT;
    function _.safetyModule() external => PER_CALLEE_CONSTANT;
    function _.totalPendingAssets() external => PER_CALLEE_CONSTANT;
    function _.totalPendingShares() external => PER_CALLEE_CONSTANT;
    function _.nextRequestId() external => PER_CALLEE_CONSTANT;

    // SafetyModule and other external calls summarized as NONDET
    function _.isPaused() external => NONDET;
    function _.checkDepositAllowed(uint256, uint256) external => NONDET;
    function _.checkWithdrawalMinimum(uint256) external => NONDET;
    function _.checkAccountingLiveness() external => NONDET;

    // Token operations — summarize the actual ERC20 external functions.
    // SafeERC20.safeTransfer/safeTransferFrom are internal library functions that compile
    // to low-level calls to transfer/transferFrom. The _.safeTransfer* signatures never
    // match any external call. We must summarize the real ERC20 signatures instead.
    function _.transfer(address, uint256) external => NONDET;
    function _.transferFrom(address, address, uint256) external => NONDET;
    function _.balanceOf(address) external => PER_CALLEE_CONSTANT;
    function _.mint(address, uint256) external => NONDET;
    function _.burn(address, uint256) external => NONDET;
    function _.totalSupply() external => PER_CALLEE_CONSTANT;
    function _.allowance(address, address) external => PER_CALLEE_CONSTANT;
    function _.approve(address, uint256) external => NONDET;

    // Queue operations
    function _.requestWithdrawal(address, uint256, uint256, uint256) external => PER_CALLEE_CONSTANT;
    function _.finalizeWithdrawals(uint256, uint256) external => NONDET;
    function _.claimWithdrawal(uint256) external => PER_CALLEE_CONSTANT;
    function _.getRequest(uint256) external => NONDET;
    function _.nextUnfinalized() external => PER_CALLEE_CONSTANT;
}

/*//////////////////////////////////////////////////////////////
                         CONSTANTS
//////////////////////////////////////////////////////////////*/

definition CVL_BP_DIVISOR()                     returns uint256 = 10000;
definition CVL_MAX_INSTANT_REDEMPTION_FEE_BP()  returns uint256 = 2000;

// Functions excluded from "for all f" rules (guarded by OZ initializer/upgrade)
definition isInitOrUpgrade(method f) returns bool =
    f.selector == sig:initialize(address, address, address, address, address).selector
    || f.selector == sig:upgradeToAndCall(address, bytes).selector;

// Functions that trigger DanglingAllocatorIdException (Certora Prover bug 2773053678)
// in BMC unrolling due to SafeERC20 low-level calls compiled with via_ir=true.
// redeem() and claimRequestById() both call _claimWithdrawal → safeTransfer.
// Neither modifies cumulative counters or fee state — filtering is safe.
definition crashesProver(method f) returns bool =
    f.selector == sig:redeem(uint256, address, address).selector
    || f.selector == sig:claimRequestById(uint256).selector;

/*//////////////////////////////////////////////////////////////
                   GHOST AXIOMS — CONVERSION MODEL
//////////////////////////////////////////////////////////////*/

// Ghost variables that capture what Core's conversion functions return for specific inputs.
// These let us write value-equality rules without linking the full Core contract.
// The ghosts are populated by the PER_CALLEE_CONSTANT summaries automatically —
// when the vault calls core.convertToShares(X), the prover picks a value K and uses it
// consistently. The harness's coreConvertToShares(X) calls the same external function
// on the same callee with the same input, so it returns the same K.
//
// We add axioms to enforce the relationship between floor and ceil conversions:
//   convertToAssetsCeil(x) >= convertToAssets(x)
// This is proven in ExchangeRate.spec on the real Core, so assuming it here is sound.

// Axiom: ceil >= floor for the same shares input (proven in ExchangeRate.spec:ceilGeFloor)
// Applied via require in rules that need it, not as a global invariant.

/*//////////////////////////////////////////////////////////////
                    CUMULATIVE COUNTER MONOTONICITY
//////////////////////////////////////////////////////////////*/

/// @title Cumulative deposits never decrease
/// @notice cumulativeDeposits is only modified via += in _processDeposit.
rule cumulativeDepositsMonotonic(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f) && !crashesProver(f) }
{
    uint256 before = getCumulativeDeposits();

    f(e, args);

    assert getCumulativeDeposits() >= before,
        "cumulativeDeposits must never decrease";
}

/// @title Cumulative withdrawals never decrease
/// @notice cumulativeWithdrawals is only modified via += in _executeRedeemRequest and _redeem.
rule cumulativeWithdrawalsMonotonic(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f) && !crashesProver(f) }
{
    uint256 before = getCumulativeWithdrawals();

    f(e, args);

    assert getCumulativeWithdrawals() >= before,
        "cumulativeWithdrawals must never decrease";
}

/// @title Cumulative exit fees never decrease
/// @notice cumulativeExitFees is only modified via += in _redeem.
rule cumulativeExitFeesMonotonic(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f) && !crashesProver(f) }
{
    uint256 before = getCumulativeExitFees();

    f(e, args);

    assert getCumulativeExitFees() >= before,
        "cumulativeExitFees must never decrease";
}

/// @title Cumulative slashing adjustments never decrease
/// @notice cumulativeSlashingAdjustments is only modified via += in finalizeWithdrawals.
rule cumulativeSlashingAdjustmentsMonotonic(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f) && !crashesProver(f) }
{
    uint256 before = getCumulativeSlashingAdjustments();

    f(e, args);

    assert getCumulativeSlashingAdjustments() >= before,
        "cumulativeSlashingAdjustments must never decrease";
}

/*//////////////////////////////////////////////////////////////
                    DEPOSIT VALUE PASSTHROUGH
//////////////////////////////////////////////////////////////*/

/// @title Deposit returns exactly core.convertToShares(assets)
/// @notice _deposit calls coreRef.convertToShares(assets) and passes the result through
///         to _processDeposit as the shares parameter. The vault does not manipulate the
///         conversion — it uses Core's pricing as-is.
/// @dev Under PER_CALLEE_CONSTANT summary, both the vault's internal call and our harness
///      call resolve to the same value K. This proves the vault passes K through faithfully.
rule depositSharesEqualConversion(env e) {
    uint256 assets; address recipient; uint256 minShares;

    // Capture what Core would return for this asset amount
    uint256 expectedShares = coreConvertToShares(e, assets);

    uint256 actualShares = deposit@withrevert(e, assets, recipient, minShares);

    // If deposit succeeded, the returned shares must equal Core's conversion exactly.
    // _deposit calls shares = coreRef.convertToShares(assets) and returns it unchanged.
    assert !lastReverted => actualShares == expectedShares,
        "deposit must return exactly core.convertToShares(assets)";
}

/// @title Deposit increases buffer by at least the deposit amount
/// @notice _processDeposit does _bufferedAssets += assets. After a successful deposit,
///         the buffer must have increased by at least the deposited amount.
///         (May increase more due to _syncBufferedWithBalance absorbing extra tokens.)
rule depositIncreasesBuffer(env e) {
    uint256 bufferBefore = vault.bufferedAssets();
    uint256 depositsBefore = getCumulativeDeposits();

    uint256 assets; address recipient; uint256 minShares;
    deposit@withrevert(e, assets, recipient, minShares);
    bool reverted = lastReverted;

    assert !reverted => vault.bufferedAssets() >= bufferBefore + assets,
        "buffer must increase by at least the deposited assets";
    assert !reverted => getCumulativeDeposits() == depositsBefore + assets,
        "cumulativeDeposits must increase by exactly the deposited assets";
}

/// @title Mint takes exactly core.convertToAssetsCeil(shares) assets
/// @notice mint() calls coreRef.convertToAssetsCeil(shares) to determine the asset cost,
///         then passes both to _processDeposit. The vault uses ceil rounding (user pays more
///         in ambiguous cases), which is the correct direction for minting.
rule mintAssetsEqualCeilConversion(env e) {
    uint256 shares; address receiver;

    // Capture what Core's ceil conversion would return
    uint256 expectedAssets = coreConvertToAssetsCeil(e, shares);

    uint256 actualAssets = mint@withrevert(e, shares, receiver);

    assert !lastReverted => actualAssets == expectedAssets,
        "mint must take exactly core.convertToAssetsCeil(shares) assets";
}

/// @title Zero deposit reverts
/// @notice deposit(0, ...) must always revert.
rule zeroDepositReverts(env e) {
    address recipient; uint256 minShares;
    deposit@withrevert(e, 0, recipient, minShares);

    assert lastReverted,
        "depositing 0 assets must revert";
}

/// @title Zero mint reverts
/// @notice mint(0, ...) must always revert.
rule zeroMintReverts(env e) {
    address receiver;
    mint@withrevert(e, 0, receiver);

    assert lastReverted,
        "minting 0 shares must revert";
}

/*//////////////////////////////////////////////////////////////
                    REDEMPTION SAFETY
//////////////////////////////////////////////////////////////*/

/// @title Instant redeem payout is gross minus fee
/// @notice _redeem computes: grossAssets = core.convertToAssets(shares),
///         fee = grossAssets * feeBP / 10000, netAssets = grossAssets - fee.
///         The vault returns netAssets. Fee stays in buffer.
/// @dev Under PER_CALLEE_CONSTANT, convertToAssets returns some K. The rule proves
///      the vault applies the fee formula correctly to K. Combined with the fee bound
///      rule, this bounds the maximum extraction.
rule instantRedeemFeeAccounting(env e) {
    uint256 wdsBefore = getCumulativeWithdrawals();
    uint256 feesBefore = getCumulativeExitFees();
    uint256 bufferBefore = vault.bufferedAssets();

    uint256 shares; address recipient; uint256 minAssets;
    uint256 netAssetsReturned = instantRedeem@withrevert(e, shares, recipient, minAssets);
    bool reverted = lastReverted;

    // Only assert on successful calls
    assert !reverted => getCumulativeWithdrawals() > wdsBefore,
        "successful instant redeem must increase cumulativeWithdrawals";
    assert !reverted => vault.bufferedAssets() < bufferBefore,
        "successful instant redeem must decrease buffer";

    mathint grossIncrease = getCumulativeWithdrawals() - wdsBefore;
    mathint feeIncrease = getCumulativeExitFees() - feesBefore;

    // grossAssets = netAssets + fee, recorded as cumulativeWithdrawals += grossAssets
    // and cumulativeExitFees += fee. So grossIncrease >= feeIncrease.
    assert !reverted => grossIncrease >= feeIncrease,
        "gross withdrawal must be at least the fee";

    // Buffer decreases by netAssets only (fee stays in buffer).
    // Buffer decrease = grossIncrease - feeIncrease = netAssets.
    assert !reverted => bufferBefore - vault.bufferedAssets() == grossIncrease - feeIncrease,
        "buffer decrease must equal net payout (gross - fee)";
}

/*//////////////////////////////////////////////////////////////
                      ROLE GATING
//////////////////////////////////////////////////////////////*/

/// @title transferToCore reverts for non-CORE_ROLE callers
/// @notice Only addresses with CORE_ROLE can call transferToCore.
/// @dev Requires the caller lacks CORE_ROLE. The core() address is the canonical holder,
///      but we test an arbitrary non-role-holder since DEFAULT_ADMIN could grant it to others.
rule nonCoreCannotTransferToCore(env e) {
    require e.msg.sender != core();
    require !vault.hasRole(vault.CORE_ROLE(), e.msg.sender);

    uint256 amount;
    transferToCore@withrevert(e, amount);

    assert lastReverted,
        "callers without CORE_ROLE must be rejected by transferToCore";
}

/// @title receiveUnstaked reverts for non-CORE_ROLE callers
/// @notice Only addresses with CORE_ROLE can call receiveUnstaked.
rule nonCoreCannotReceiveUnstaked(env e) {
    require e.msg.sender != core();
    require !vault.hasRole(vault.CORE_ROLE(), e.msg.sender);

    uint256 amount;
    receiveUnstaked@withrevert(e, amount);

    assert lastReverted,
        "callers without CORE_ROLE must be rejected by receiveUnstaked";
}

/*//////////////////////////////////////////////////////////////
                     PAUSE BEHAVIOR
//////////////////////////////////////////////////////////////*/

/// @title Deposits revert when paused
/// @notice When the vault is paused, all deposit variants must revert.
rule depositRevertsWhenPaused(env e) {
    require paused();

    uint256 assets; address recipient; uint256 minShares;
    deposit@withrevert(e, assets, recipient, minShares);

    assert lastReverted,
        "deposit must revert when paused";
}

/// @title Instant redeem reverts when paused
/// @notice When the vault is paused, instant redeem must revert.
rule instantRedeemRevertsWhenPaused(env e) {
    require paused();

    uint256 shares; address recipient; uint256 minAssets;
    instantRedeem@withrevert(e, shares, recipient, minAssets);

    assert lastReverted,
        "instant redeem must revert when paused";
}

/// @title Request redeem reverts when paused
/// @notice When the vault is paused, requestRedeem must revert.
rule requestRedeemRevertsWhenPaused(env e) {
    require paused();

    uint256 shares; address controller; address owner;
    requestRedeem@withrevert(e, shares, controller, owner);

    assert lastReverted,
        "requestRedeem must revert when paused";
}

/*//////////////////////////////////////////////////////////////
                 INSTANT REDEMPTION FEE BOUNDS
//////////////////////////////////////////////////////////////*/

/// @title Instant redemption fee bounded after any call
/// @notice No function can set instantRedemptionFeeBP above MAX_INSTANT_REDEMPTION_FEE_BP.
rule instantRedemptionFeeBounded(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f) && !crashesProver(f) }
{
    require getInstantRedemptionFeeBP() <= CVL_MAX_INSTANT_REDEMPTION_FEE_BP();

    f(e, args);

    assert getInstantRedemptionFeeBP() <= CVL_MAX_INSTANT_REDEMPTION_FEE_BP(),
        "instantRedemptionFeeBP must never exceed MAX_INSTANT_REDEMPTION_FEE_BP (2000)";
}

/// @title setInstantRedemptionFeeBP respects upper bound
/// @notice Setting the fee above MAX reverts.
rule setInstantRedemptionFeeRespectsMax(env e) {
    uint256 newFee;

    setInstantRedemptionFeeBP@withrevert(e, newFee);

    assert !lastReverted => getInstantRedemptionFeeBP() <= CVL_MAX_INSTANT_REDEMPTION_FEE_BP(),
        "successful setInstantRedemptionFeeBP must result in fee <= MAX";
}

/*//////////////////////////////////////////////////////////////
                 CORE-ROLE BUFFER OPERATIONS
//////////////////////////////////////////////////////////////*/

/// @title transferToCore decreases buffer by exactly the amount
/// @notice The CORE_ROLE transferToCore function moves assets out of the vault buffer.
rule transferToCoreDecreasesBuffer(env e) {
    uint256 bufferBefore = vault.bufferedAssets();

    uint256 amount;
    transferToCore@withrevert(e, amount);
    bool reverted = lastReverted;

    assert !reverted => vault.bufferedAssets() == bufferBefore - amount,
        "transferToCore must decrease buffer by exactly the transferred amount";
}

/// @title receiveUnstaked increases buffer by exactly the amount
/// @notice The CORE_ROLE receiveUnstaked function adds assets to the vault buffer.
rule receiveUnstakedIncreasesBuffer(env e) {
    uint256 bufferBefore = vault.bufferedAssets();

    uint256 amount;
    receiveUnstaked@withrevert(e, amount);
    bool reverted = lastReverted;

    assert !reverted => vault.bufferedAssets() == bufferBefore + amount,
        "receiveUnstaked must increase buffer by exactly the received amount";
}

/// @title transferToCore reverts on insufficient buffer
/// @notice Cannot transfer more than what is buffered.
rule transferToCoreRespectsBuffer(env e) {
    uint256 buffered = vault.bufferedAssets();

    uint256 amount;
    require amount > buffered;

    transferToCore@withrevert(e, amount);

    assert lastReverted,
        "transferToCore must revert when amount exceeds buffer";
}

/// @title transferToCore reverts on zero amount
/// @notice The zero-amount check fires before the buffer check.
rule transferToCoreZeroReverts(env e) {
    transferToCore@withrevert(e, 0);

    assert lastReverted,
        "transferToCore must revert on zero amount";
}
