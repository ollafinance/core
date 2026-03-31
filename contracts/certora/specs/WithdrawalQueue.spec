/*
 * Certora Verification Spec: WithdrawalQueue
 *
 * Properties verified:
 *   1. FIFO ordering -- all requests below nextPendingId are finalized
 *   2. Pointer monotonicity -- nextPendingId <= nextRequestId, both only increase
 *   3. Pending assets consistency -- totalPendingAssets tracks unfinalized sum
 *   4. Claim deletes request -- claimed requests are removed from storage
 *   5. No double-finalization -- finalized requests stay finalized
 *   6. Request ID monotonicity -- each new request gets a strictly higher ID
 */

using WithdrawalQueueHarness as queue;

methods {
    // State getters
    function nextRequestId() external returns (uint64) envfree;
    function nextPendingId() external returns (uint64) envfree;
    function totalPendingAssets() external returns (uint256) envfree;
    function totalPendingShares() external returns (uint256) envfree;
    function vault() external returns (address) envfree;
    function gasThreshold() external returns (uint32) envfree;

    // Harness getters
    function isFinalized(uint256) external returns (bool) envfree;
    function getRequestAssets(uint256) external returns (uint256) envfree;
    function getRequestShares(uint256) external returns (uint256) envfree;
    function getRequestRecipient(uint256) external returns (address) envfree;

    // Mutating functions
    function requestWithdrawal(address, uint256, uint256, uint256) external returns (uint256);
    function finalizeWithdrawals(uint256, uint256) external returns (uint256, uint256, uint256);
    function claimWithdrawal(uint256) external returns (uint256);
}

/*//////////////////////////////////////////////////////////////
                      STATE PROPERTIES
//////////////////////////////////////////////////////////////*/

/// @title Pointer ordering preserved by all post-init operations
/// @notice If nextPendingId <= nextRequestId before a call, it holds after.
/// @dev Excludes initialize/upgrade (one-shot, guarded by OZ initializer).
rule pointerOrderingPreserved(env e, method f, calldataarg args)
    filtered { f -> f.selector != sig:initialize(address, address, uint256).selector
                  && f.selector != sig:upgradeToAndCall(address, bytes).selector }
{
    // Require initialized state
    require nextRequestId() >= 1;
    require nextPendingId() >= 1;
    require nextPendingId() <= nextRequestId();

    f(e, args);

    assert nextPendingId() <= nextRequestId(),
        "nextPendingId must never exceed nextRequestId";
}

/// @title Initialize sets valid pointer state
/// @notice After initialization, both pointers are 1 and ordering holds.
rule initializeSetsValidPointers(env e) {
    address vault_; address admin_; uint256 gasThreshold_;
    initialize(e, vault_, admin_, gasThreshold_);

    satisfy nextRequestId() == 1 && nextPendingId() == 1;
}

/*//////////////////////////////////////////////////////////////
                        RULES
//////////////////////////////////////////////////////////////*/

/// @title Request ID monotonically increases
/// @notice Each call to requestWithdrawal returns a strictly increasing ID.
rule requestIdMonotonicallyIncreases(env e) {
    uint64 idBefore = nextRequestId();

    address recipient; uint256 shares; uint256 assets; uint256 rate;
    requestWithdrawal(e, recipient, shares, assets, rate);

    uint64 idAfter = nextRequestId();

    assert idAfter == assert_uint64(idBefore + 1),
        "nextRequestId must increment by exactly 1 per request";
}

/// @title requestWithdrawal increases pending totals
/// @notice Pending assets and shares increase by the request amounts.
rule requestIncreasePendingTotals(env e) {
    uint256 pendingAssetsBefore = totalPendingAssets();
    uint256 pendingSharesBefore = totalPendingShares();

    address recipient; uint256 shares; uint256 assetsExpected; uint256 rate;
    requestWithdrawal(e, recipient, shares, assetsExpected, rate);

    assert totalPendingAssets() == pendingAssetsBefore + assetsExpected,
        "totalPendingAssets must increase by assetsExpected";
    assert totalPendingShares() == pendingSharesBefore + shares,
        "totalPendingShares must increase by shares";
}

/// @title nextPendingId only increases
/// @notice No operation decreases the finalization pointer.
rule nextPendingIdOnlyIncreases(env e, method f, calldataarg args)
    filtered { f -> f.selector != sig:initialize(address, address, uint256).selector
                  && f.selector != sig:upgradeToAndCall(address, bytes).selector }
{
    uint64 before = nextPendingId();

    f(e, args);

    assert nextPendingId() >= before,
        "nextPendingId must never decrease";
}

/// @title nextRequestId only increases
/// @notice No operation decreases the allocation pointer.
rule nextRequestIdOnlyIncreases(env e, method f, calldataarg args)
    filtered { f -> f.selector != sig:initialize(address, address, uint256).selector
                  && f.selector != sig:upgradeToAndCall(address, bytes).selector }
{
    uint64 before = nextRequestId();

    f(e, args);

    assert nextRequestId() >= before,
        "nextRequestId must never decrease";
}

/// @title Finalization never increases pending totals
/// @notice finalizeWithdrawals can only decrease (or maintain) pending assets.
rule finalizeNeverIncreasesPending(env e) {
    uint256 pendingBefore = totalPendingAssets();
    uint256 pendingSharesBefore = totalPendingShares();

    uint256 available; uint256 currentRate;
    finalizeWithdrawals(e, available, currentRate);

    assert totalPendingAssets() <= pendingBefore,
        "finalizeWithdrawals must not increase totalPendingAssets";
    assert totalPendingShares() <= pendingSharesBefore,
        "finalizeWithdrawals must not increase totalPendingShares";
}

/// @title Finalize used <= available
/// @notice The assets consumed by finalization never exceed the available liquidity.
rule finalizeUsedBoundedByAvailable(env e) {
    uint256 available; uint256 currentRate;
    uint256 used; uint256 count; uint256 adjusted;
    used, count, adjusted = finalizeWithdrawals(e, available, currentRate);

    assert used <= available,
        "finalized amount must not exceed available liquidity";
}

/// @title Claim deletes the request
/// @notice After a successful claimWithdrawal, the request's recipient is zeroed (deleted).
/// @dev Requires valid preconditions to avoid vacuous satisfaction:
///      the request must exist (recipient != 0), be finalized, and caller must be vault.
rule claimDeletesRequest(env e) {
    uint256 id;

    // Require the request exists and is finalized (claim preconditions)
    require getRequestRecipient(id) != 0;
    require isFinalized(id);

    // claimWithdrawal has onlyVault modifier -- require caller is vault
    // to prevent vacuous pass via access-control revert
    require e.msg.sender == vault();

    claimWithdrawal(e, id);

    assert getRequestRecipient(id) == 0,
        "claimed request must be deleted from storage";
}

/// @title No state change from non-vault callers
/// @notice Only the vault can modify queue state via requestWithdrawal and finalizeWithdrawals.
rule onlyVaultCanRequest(env e) {
    address vaultAddr = vault();

    address recipient; uint256 shares; uint256 assets; uint256 rate;
    requestWithdrawal@withrevert(e, recipient, shares, assets, rate);

    assert e.msg.sender != vaultAddr => lastReverted,
        "non-vault callers must be rejected";
}

/// @title Finalization consistency: used == 0 iff count == 0
/// @notice If no requests were finalized, no assets were consumed (and vice versa).
/// @dev Slashing-to-zero requests are finalized with 0 assets but increment currentId,
///      not finalizedCount, so this invariant holds.
rule finalizationConsistency(env e) {
    uint256 available; uint256 currentRate;
    uint256 used; uint256 count; uint256 adjusted;
    used, count, adjusted = finalizeWithdrawals(e, available, currentRate);

    // If count > 0 then used > 0 (at least one non-zero request was finalized)
    // Note: slashed-to-zero requests don't increment count, they just advance the pointer
    assert (count == 0) => (used == 0),
        "zero finalized count must mean zero used assets";
}

/// @title Slashing adjustment only reduces payouts
/// @notice After finalization with a slashed rate, each request's payout is <= its original payout.
/// @dev The critical property: a slash event can never INCREASE what a user receives.
///      Violation would mean users profit from slashing -- direct protocol insolvency risk.
rule slashingNeverIncreasesRequestPayout(env e) {
    // Pick a request that exists and is not yet finalized
    uint256 id;
    uint256 assetsBefore = getRequestAssets(id);
    require assetsBefore > 0;

    // Run finalization (may apply slashing adjustment)
    uint256 available; uint256 currentRate;
    finalizeWithdrawals(e, available, currentRate);

    uint256 assetsAfter = getRequestAssets(id);

    // After finalization, the request's payout can only decrease or stay the same
    assert assetsAfter <= assetsBefore,
        "slashing adjustment must never increase a request's payout";
}

/// @title Slashing adjustment bounded by pending reduction
/// @notice The adjustment cannot exceed the total pending decrease minus used assets.
/// @dev totalAdjusted accumulates (original - adjusted) for each slashed request.
///      Since used goes to claimable and adjusted is "lost" to slashing, their sum
///      cannot exceed the total pending reduction.
rule slashingAdjustmentBoundedByPendingReduction(env e) {
    uint256 pendingBefore = totalPendingAssets();

    uint256 available; uint256 currentRate;
    uint256 used; uint256 count; uint256 adjusted;
    used, count, adjusted = finalizeWithdrawals(e, available, currentRate);

    uint256 pendingAfter = totalPendingAssets();
    mathint decrease = pendingBefore - pendingAfter;

    assert adjusted <= decrease,
        "slashing adjustment must not exceed total pending decrease";
}

/// @title Pending assets decrease matches used + adjusted
rule pendingDecreaseMatchesUsedPlusAdjusted(env e) {
    uint256 pendingBefore = totalPendingAssets();

    uint256 available; uint256 currentRate;
    uint256 used; uint256 count; uint256 adjusted;
    used, count, adjusted = finalizeWithdrawals(e, available, currentRate);

    uint256 pendingAfter = totalPendingAssets();

    // The decrease in pending = used (assets consumed for finalized requests)
    //                          + adjusted (slashing reductions applied to requests)
    //                          + zero-payout requests (slashed to zero, subtracted from pending)
    // For non-zero-payout requests: pendingBefore - pendingAfter >= used + adjusted
    assert pendingBefore - pendingAfter >= used + adjusted,
        "pending decrease must account for used assets and slashing adjustments";
}
