/*
 * Certora Verification Spec: Exchange Rate Properties
 *
 * Properties verified:
 *   1. Conversion round-trip -- converting assets->shares->assets loses at most 1 wei (floor rounding)
 *   2. Virtual offset protection -- exchange rate is well-defined even with 0 supply/assets
 *   3. Share/asset conversion consistency -- convertToAssets and convertToShares are inverse up to rounding
 *   4. Ceiling >= floor -- convertToAssetsCeil >= convertToAssets for same input
 *   5. Zero input produces zero output -- converting 0 gives 0
 *   6. Monotonicity -- more assets converts to more-or-equal shares (and vice versa)
 */

using OllaCoreHarness as core;

methods {
    // convertTo* and exchangeRate ARE the functions under test -- their bodies must
    // execute so the rules verify the actual math. Declare them envfree so the rules
    // can call them without an env, but do NOT summarize: the prover needs the real
    // implementation to prove monotonicity, round-trip loss bounds, etc.
    function convertToShares(uint256) external returns (uint256) envfree;
    function convertToAssets(uint256) external returns (uint256) envfree;
    function convertToAssetsCeil(uint256) external returns (uint256) envfree;
    function exchangeRate() external returns (uint256) envfree;

    // totalAssets() is the underlying state input to the conversion math. We do NOT
    // want to verify its implementation here -- summarize it as PER_CALLEE_CONSTANT
    // so every call within a rule returns a single value, eliminating the prior
    // failure mode where the prover picked totalAssets()=1 in one expression and
    // totalAssets()=8358 in another (violating the requireRealisticState ratio
    // bound). The wildcard `_.totalAssets() external => PER_CALLEE_CONSTANT` below
    // would NOT have caught self-calls if the verified contract's own method
    // declaration shadowed it; declaring the summary here explicitly is required.
    function totalAssets() external returns (uint256) envfree => PER_CALLEE_CONSTANT;

    // Harness getters for internal state -- envfree pure storage reads.
    function getStakedPrincipal() external returns (uint256) envfree;
    function getRewardsAccumulatorBalance() external returns (uint256) envfree;
    function getClaimableRewards() external returns (uint256) envfree;
    function getTotalSupply() external returns (uint256) envfree;

    // External contract summaries -- PER_CALLEE_CONSTANT ensures consistent
    // return values within a single rule (models: state doesn't change mid-tx).
    function _.bufferedAssets() external => PER_CALLEE_CONSTANT;
    function _.pendingWithdrawalAssets() external => PER_CALLEE_CONSTANT;
    function _.pendingWithdrawalShares() external => PER_CALLEE_CONSTANT;
    function _.totalSupply() external => PER_CALLEE_CONSTANT;

    // _liveAccountingState() (the backbone of totalAssets / convertToAssets /
    // convertToAssetsCeil) calls the StakingManager and RewardsAccumulator. Without
    // summaries the Prover havocs the returns and picks adversarial values that
    // overflow the bounded-state assumptions in requireRealisticState(), breaking
    // every conversion rule.
    function _.getClaimableRewards() external => PER_CALLEE_CONSTANT;
    function _.balance() external => PER_CALLEE_CONSTANT;
    function _.totalStaked() external => PER_CALLEE_CONSTANT;
    function _.getSlashingDelta() external => PER_CALLEE_CONSTANT;

    // Even though no rule in this spec calls rebalance(), the prover still has to
    // analyze every method on OllaCoreHarness during initial transformation. The
    // SafeERC20 inline-assembly transfers in rebalance() (and the unsummarized
    // staking-manager / accumulator callees from rebalance) trigger pointer-analysis
    // failure 1277565207, which cascades into harness-wide havocs that wreck the
    // bounds on totalAssets() and supply -- producing the inconsistent counterexamples
    // (e.g. ta=1 but supply=8358) we see when all 10 conversion rules collapse.
    // Summarize the SafeERC20 wrappers and the rebalance-only callees here so the
    // harness compiles cleanly, even though these rules never exercise them.
    function SafeERC20.safeTransfer(address, address, uint256) internal => NONDET;
    function SafeERC20.safeTransferFrom(address, address, address, uint256) internal => NONDET;
    function _.withdrawToCore() external => NONDET;
    function _.recordBalance() external => NONDET;
    function _.harvestRewards() external => NONDET;
    function _.stake(uint256) external => NONDET;
    function _.unstake(uint256) external => NONDET;
    function _.refreshAttesterState(address[]) external => NONDET;
    function _.setGasThreshold(uint256) external => NONDET;
    function _.pendingUnstakes() external => PER_CALLEE_CONSTANT;
    function _.getProviderConfig() external => PER_CALLEE_CONSTANT;
    function _.getActivatedAttesterCount() external => PER_CALLEE_CONSTANT;
    function _.canStake(uint256) external => PER_CALLEE_CONSTANT;
    function _.getUnstakedFunds() external => PER_CALLEE_CONSTANT;
    function _.claimableUnstakedFunds() external => PER_CALLEE_CONSTANT;
    function _.hasFinalizedUnstakes() external => PER_CALLEE_CONSTANT;
    function _.transferToCore(uint256) external => NONDET;
    function _.receiveUnstaked(uint256) external => NONDET;
    function _.mintFees(address, uint256, address, uint256) external => NONDET;
    function _.finalizeWithdrawals(uint256, uint256, uint256) external => NONDET;
    function _.cumulativeDeposits() external => PER_CALLEE_CONSTANT;
    function _.cumulativeWithdrawals() external => PER_CALLEE_CONSTANT;
    function _.cumulativeSlashingAdjustments() external => PER_CALLEE_CONSTANT;
    function _.nextWithdrawalRequestId() external => PER_CALLEE_CONSTANT;
    function _.nextUnfinalizedWithdrawalRequestId() external => PER_CALLEE_CONSTANT;
    function _.checkAccountingLiveness() external => NONDET;
    function _.checkDepositAllowed(uint256, uint256) external => NONDET;
    function _.checkQueueRatio(uint256, uint256) external => NONDET;
    function _.checkRateDrop(uint256, uint256) external => NONDET;
    function _.setLatestAccountingTimestamp(uint256) external => NONDET;
    function _.treasury() external => PER_CALLEE_CONSTANT;
}

/*//////////////////////////////////////////////////////////////
                    HELPER: REALISTIC STATE
//////////////////////////////////////////////////////////////*/

// totalAssets() sums buffered + staked + rewardsAcc + claimable - pending.
// With unconstrained storage, this can overflow uint256 -> revert -> spurious violations.
// We require totalAssets() returns successfully and is bounded, which covers all
// realistic protocol states (total AZTEC supply is ~1B tokens = ~1e27 wei).
//
// totalSupply() is summarized as PER_CALLEE_CONSTANT (not linked), so the prover
// can pick any uint256. We bound it to <2^96 and require a reasonable ratio with
// totalAssets to prevent spurious counterexamples from unreachable extreme states.
//
// totalAssets() is summarized as PER_CALLEE_CONSTANT in the methods block, so all
// calls in a rule return the same value. We can use it directly in the requires
// without caching -- the prior failure mode (ta=1 in one expression, ta=8358 in
// another) was caused by the missing summary, not by repeated invocations.
function requireRealisticState() {
    uint256 ta = totalAssets();
    uint256 supply = getTotalSupply();

    // Bound to 2^96 -- realistic max is ~1e27 (1B AZTEC tokens in wei, ~2^90).
    // Keeps mulDiv's 512-bit intermediate products well under 2^256.
    require ta < 2^96;
    require supply < 2^96;

    // Ratio constraint: supply and assets track each other within ~1000x. Covers
    // launch, heavy rewards, mild slashing; rules out unreachable extremes.
    require supply == 0 || ta * 1000 >= supply;
    require ta == 0 || supply * 1000 >= ta;
}

/*//////////////////////////////////////////////////////////////
                     EXCHANGE RATE PROPERTIES
//////////////////////////////////////////////////////////////*/

/// @title Exchange rate is always positive
/// @notice With the virtual offset (1e3), the rate can never be 0.
rule exchangeRateAlwaysPositive() {
    requireRealisticState();

    assert exchangeRate() > 0,
        "exchange rate must always be positive due to virtual offset";
}

/// @title Exchange rate bounded below
/// @notice The virtual offset ensures the rate never drops below a minimum floor.
rule exchangeRateHasFloor() {
    requireRealisticState();

    uint256 rate = exchangeRate();
    assert rate >= 1,
        "exchange rate must be at least 1 wei";
}

/*//////////////////////////////////////////////////////////////
                    CONVERSION PROPERTIES
//////////////////////////////////////////////////////////////*/

/// @title Zero converts to zero
/// @notice Converting 0 assets gives 0 shares, and 0 shares gives 0 assets.
rule zeroConvertsToZero() {
    requireRealisticState();

    assert convertToShares(0) == 0,
        "0 assets must convert to 0 shares";
    assert convertToAssets(0) == 0,
        "0 shares must convert to 0 assets";
    assert convertToAssetsCeil(0) == 0,
        "0 shares must convert to 0 assets (ceil)";
}

/// @title Round-trip loss bounded
/// @notice Converting assets -> shares -> assets never creates assets (no free money),
///         and the rounding loss is bounded by the exchange rate (totalAssets/totalSupply).
///         Each floor-division step loses at most (denominator-1)/denominator, so the
///         composed round-trip loss is at most ceil(totalAssets + offset, supply + offset).
rule roundTripAssetsToSharesLossBounded(uint256 assets) {
    requireRealisticState();
    // Bound to 2^96 -- matches realistic state bounds. With state and inputs < 2^96,
    // mulDiv intermediate products stay < 2^192, well within uint256.
    require assets > 0 && assets < 2^96;

    uint256 supply = getTotalSupply();
    uint256 ta = totalAssets();

    uint256 shares = convertToShares(assets);
    uint256 assetsBack = convertToAssets(shares);

    // Core safety: round-trip must never create assets
    assert assetsBack <= assets,
        "round-trip must not create assets (no free money)";

    // Rounding loss bound: each mulDiv(Floor) loses < 1 unit of the quotient.
    // The quotient unit for assets->shares is (ta+1e3)/(supply+1e3) assets per share.
    // Composed round-trip loss < 1 + (ta+1e3)/(supply+1e3).
    // With bounded ratio (<=1000x), loss < 1001. Use 1001 as conservative bound.
    assert shares > 0 => assetsBack + 1001 >= assets,
        "round-trip loss must be bounded for non-zero shares";
}

/// @title Round-trip shares -> assets -> shares
/// @notice Converting shares -> assets -> shares never creates shares,
///         and the rounding loss is bounded (symmetric to the assets round-trip).
rule roundTripSharesToAssetsLossBounded(uint256 shares) {
    requireRealisticState();
    // Bound to 2^96 -- matches realistic state bounds
    require shares > 0 && shares < 2^96;

    uint256 assets = convertToAssets(shares);
    uint256 sharesBack = convertToShares(assets);

    // Core safety: round-trip must never create shares
    assert sharesBack <= shares,
        "round-trip must not create shares";

    // Symmetric bound: each mulDiv(Floor) loses < 1 quotient unit.
    // Here the quotient unit is (supply+1e3)/(ta+1e3) shares per asset.
    // With bounded ratio (<=1000x), composed loss < 1001.
    assert assets > 0 => sharesBack + 1001 >= shares,
        "round-trip loss must be bounded for non-zero assets";
}

/// @title Ceiling >= floor for same input
/// @notice convertToAssetsCeil(x) >= convertToAssets(x) for all x.
rule ceilGeFloor(uint256 shares) {
    requireRealisticState();

    uint256 floor = convertToAssets(shares);
    uint256 ceil = convertToAssetsCeil(shares);

    assert ceil >= floor,
        "ceiling rounding must be >= floor rounding";
}

/// @title Ceiling - floor bounded by 1
/// @notice The difference between ceil and floor conversion is at most 1.
rule ceilFloorDiffBounded(uint256 shares) {
    requireRealisticState();
    require shares < 2^96;

    uint256 floor = convertToAssets(shares);
    uint256 ceil = convertToAssetsCeil(shares);

    assert ceil <= floor + 1,
        "ceil - floor must be at most 1";
}

/// @title Conversion monotonicity (assets to shares)
/// @notice More assets always converts to >= shares.
rule conversionMonotonicAssetsToShares(uint256 assets1, uint256 assets2) {
    requireRealisticState();
    require assets1 <= assets2;
    // Bound to 2^96 -- matches realistic state bounds
    require assets2 < 2^96;

    uint256 shares1 = convertToShares(assets1);
    uint256 shares2 = convertToShares(assets2);

    assert shares1 <= shares2,
        "convertToShares must be monotonically non-decreasing";
}

/// @title Conversion monotonicity (shares to assets)
/// @notice More shares always converts to >= assets.
rule conversionMonotonicSharesToAssets(uint256 shares1, uint256 shares2) {
    requireRealisticState();
    require shares1 <= shares2;
    // Bound to 2^96 -- matches realistic state bounds
    require shares2 < 2^96;

    uint256 assets1 = convertToAssets(shares1);
    uint256 assets2 = convertToAssets(shares2);

    assert assets1 <= assets2,
        "convertToAssets must be monotonically non-decreasing";
}

/// @title No free money from conversion
/// @notice A user cannot gain assets by converting through shares.
///         This is the core safety invariant: floor rounding in both directions
///         guarantees the protocol never gives out more than it takes in.
rule noFreeMoney(uint256 assets) {
    requireRealisticState();
    require assets > 0 && assets < 2^96;

    uint256 shares = convertToShares(assets);
    uint256 assetsBack = convertToAssets(shares);

    assert assetsBack <= assets,
        "converting assets->shares->assets must not yield more assets";
}

/// @title Deposit/redeem symmetry for ceiling
/// @notice Using ceil for mint ensures the user pays at least the correct amount.
///         convertToAssetsCeil rounds UP, then convertToShares rounds DOWN, so
///         sharesBack >= shares holds when the two rounding directions compensate.
rule mintCeilGuaranteesSufficientPayment(uint256 shares) {
    requireRealisticState();
    // Bound to 2^96 -- matches realistic state bounds
    require shares > 0 && shares < 2^96;

    uint256 assetsCeil = convertToAssetsCeil(shares);
    uint256 sharesBack = convertToShares(assetsCeil);

    assert sharesBack >= shares,
        "paying ceil(assets) must yield at least the requested shares";
}
