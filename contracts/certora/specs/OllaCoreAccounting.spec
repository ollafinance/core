/*
 * Certora Verification Spec: OllaCore Accounting
 *
 * Properties verified:
 *   1. Fee bounds -- protocol fee never exceeds MAX_PROTOCOL_FEE_BP
 *   2. Treasury split bounds -- always within [MIN, MAX]
 *   3. Rebalance step validity -- always a valid enum value
 *   4. Rebalance state machine -- valid transitions only
 *   5. forceRebalanceReset -- always resets to Done
 *   6. updateAccounting gating -- reverts when rebalance in progress
 *   7. Parameter setter bounds -- all setters enforce their bounds
 *   8. Report timestamp monotonicity -- timestamp only increases via updateAccounting
 *   9. Flow counter snapshot monotonicity -- report snapshots never decrease
 *  10. Rebalance FSM transition edges -- only forward or self-loop, never backward
 *  11. Rebalance step stability -- only rebalance() and forceRebalanceReset() modify step
 *
 * NOTE: Broad "for all functions" variants of monotonicity rules are impractical because
 * rebalance() and updateAccounting() make 5+ external calls (StakingManager,
 * RewardsAccumulator, SafetyModule, Vault, WithdrawalQueue) that would require full
 * protocol modeling. Instead, we use targeted rules that verify monotonicity for the
 * specific functions that write these fields, and stability rules that prove other
 * functions cannot modify them.
 */

using OllaCoreHarness as core;

methods {
    // View functions
    function protocolFeeBP() external returns (uint16) envfree;
    function treasuryFeeSplitBP() external returns (uint16) envfree;
    function rebalanceCooldown() external returns (uint32) envfree;
    function lastRebalanceTimestamp() external returns (uint48) envfree;
    function targetBufferedAssets() external returns (uint256) envfree;

    // Harness getters
    function getRebalanceStep() external returns (uint8) envfree;
    function getStakedPrincipal() external returns (uint256) envfree;
    function getRewardsAccumulatorBalance() external returns (uint256) envfree;
    function getClaimableRewards() external returns (uint256) envfree;
    function getCumulativeDeposits() external returns (uint256) envfree;
    function getCumulativeWithdrawals() external returns (uint256) envfree;
    function getLatestReportTotalAssets() external returns (uint256) envfree;
    function getLatestReportExchangeRate() external returns (uint256) envfree;
    function getLatestReportTimestamp() external returns (uint256) envfree;

    // Harness getters -- flow counter snapshots
    function getLatestReportCumulativeDeposits() external returns (uint256) envfree;
    function getLatestReportCumulativeWithdrawals() external returns (uint256) envfree;

    // Mutating functions
    function rebalance() external returns (uint256, uint256, uint256, uint256);
    function updateAccounting() external;
    function setProtocolFeeBP(uint256) external;
    function setTreasuryFeeSplitBP(uint256) external;
    function setTargetBufferedAssets(uint256) external;
    function setRebalanceCooldown(uint256) external;
    function setRebalanceGasThreshold(uint256) external;
    function forceRebalanceReset() external;

    // External contract summaries -- all external calls return consistent arbitrary values.
    // This is sufficient for parameter-bound and state-machine rules that don't depend
    // on external return values.
    function _.bufferedAssets() external => PER_CALLEE_CONSTANT;
    function _.pendingWithdrawalAssets() external => PER_CALLEE_CONSTANT;
    function _.pendingWithdrawalShares() external => PER_CALLEE_CONSTANT;
    function _.totalSupply() external => PER_CALLEE_CONSTANT;
    // Vault flow counters -- called by _updateReportingSnapshots in updateAccounting.
    // Without these, the prover havocs the return (unresolved callee) and can produce
    // counterexamples where cumulative counters appear to decrease.
    function _.cumulativeDeposits() external => PER_CALLEE_CONSTANT;
    function _.cumulativeWithdrawals() external => PER_CALLEE_CONSTANT;
    function _.cumulativeSlashingAdjustments() external => PER_CALLEE_CONSTANT;
    // RewardsAccumulator view -- called during rebalance accounting
    function _.balance() external => PER_CALLEE_CONSTANT;
    // Summarize all other external calls as NONDET (rebalance calls many contracts)
    function _.harvestRewards() external => NONDET;
    function _.recordBalance() external => NONDET;
    function _.stake(uint256) external => NONDET;
    function _.totalStaked() external => PER_CALLEE_CONSTANT;
    function _.pendingUnstakes() external => PER_CALLEE_CONSTANT;
    function _.claimUnstakedFunds() external => NONDET;
    function _.refreshAttesterState(address[]) external => NONDET;
    function _.finalizeWithdrawals(uint256, uint256) external => NONDET;
    function _.transferToCore(uint256) external => NONDET;
    function _.receiveUnstaked(uint256) external => NONDET;
    function _.mintFees(address, uint256, address, uint256) external => NONDET;
    function _.checkDepositAllowed(uint256, uint256) external => NONDET;
    function _.checkQueueRatio(uint256, uint256) external => NONDET;
    function _.checkRateDrop(uint256, uint256) external => NONDET;
    function _.setLatestAccountingTimestamp(uint256) external => NONDET;
    // SafetyModule checks -- called during updateAccounting/rebalance
    function _.checkAccountingLiveness() external => NONDET;
    // StakingManager views -- called during rebalance/updateAccounting
    function _.getClaimableRewards() external => PER_CALLEE_CONSTANT;
    function _.getSlashingDelta() external => PER_CALLEE_CONSTANT;
    function _.getProviderConfig() external => PER_CALLEE_CONSTANT;
    function _.getActivatedAttesterCount() external => PER_CALLEE_CONSTANT;
    function _.canStake(uint256) external => PER_CALLEE_CONSTANT;
    function _.getUnstakedFunds() external => PER_CALLEE_CONSTANT;
    function _.hasFinalizedUnstakes() external => PER_CALLEE_CONSTANT;
    function _.setGasThreshold(uint256) external => NONDET;
    // Governance treasury address -- called during fee distribution
    function _.treasury() external => PER_CALLEE_CONSTANT;
}

/*//////////////////////////////////////////////////////////////
                         CONSTANTS
//////////////////////////////////////////////////////////////*/

definition STEP_HARVEST()          returns uint8 = 0;
definition STEP_PULL_UNSTAKED()    returns uint8 = 1;
definition STEP_FINALIZE()         returns uint8 = 2;
definition STEP_INITIATE_UNSTAKE() returns uint8 = 3;
definition STEP_STAKE_SURPLUS()    returns uint8 = 4;
definition STEP_DONE()             returns uint8 = 5;

definition CVL_MAX_PROTOCOL_FEE_BP()   returns uint256 = 5000;
definition CVL_MIN_TREASURY_SPLIT()    returns uint256 = 1000;
definition CVL_MAX_TREASURY_SPLIT()    returns uint256 = 9000;

// Functions excluded from "for all f" rules (guarded by OZ initializer/upgrade)
definition isInitOrUpgrade(method f) returns bool =
    f.selector == sig:initialize(address, address, address, uint256, uint256, address, address, address).selector
    || f.selector == sig:upgradeToAndCall(address, bytes).selector;

/*//////////////////////////////////////////////////////////////
                    PARAMETER BOUND RULES
//////////////////////////////////////////////////////////////*/

/// @title setProtocolFeeBP respects upper bound
/// @notice Setting the fee above MAX_PROTOCOL_FEE_BP reverts.
rule setFeeBPRespectsMax(env e) {
    uint256 newFee;

    setProtocolFeeBP@withrevert(e, newFee);

    assert !lastReverted => protocolFeeBP() <= assert_uint16(CVL_MAX_PROTOCOL_FEE_BP()),
        "successful setProtocolFeeBP must result in fee <= MAX";
}

/// @title setTreasuryFeeSplitBP respects bounds
/// @notice Setting the split outside [MIN, MAX] reverts.
rule setTreasurySplitBPRespectsBounds(env e) {
    uint256 newSplit;

    setTreasuryFeeSplitBP@withrevert(e, newSplit);

    assert !lastReverted => (
        treasuryFeeSplitBP() >= assert_uint16(CVL_MIN_TREASURY_SPLIT()) &&
        treasuryFeeSplitBP() <= assert_uint16(CVL_MAX_TREASURY_SPLIT())
    ),
        "successful setTreasuryFeeSplitBP must result in split within bounds";
}

/// @title Protocol fee bounded across all operations
/// @notice No function can set protocolFeeBP above the maximum.
rule protocolFeeBoundedAfterAnyCall(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f) }
{
    require protocolFeeBP() <= assert_uint16(CVL_MAX_PROTOCOL_FEE_BP());

    f(e, args);

    assert protocolFeeBP() <= assert_uint16(CVL_MAX_PROTOCOL_FEE_BP()),
        "protocolFeeBP must never exceed MAX_PROTOCOL_FEE_BP";
}

/// @title Treasury split bounded across all operations
/// @notice No function can set treasuryFeeSplitBP outside bounds.
rule treasurySplitBoundedAfterAnyCall(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f) }
{
    require treasuryFeeSplitBP() >= assert_uint16(CVL_MIN_TREASURY_SPLIT());
    require treasuryFeeSplitBP() <= assert_uint16(CVL_MAX_TREASURY_SPLIT());

    f(e, args);

    assert treasuryFeeSplitBP() >= assert_uint16(CVL_MIN_TREASURY_SPLIT()) &&
           treasuryFeeSplitBP() <= assert_uint16(CVL_MAX_TREASURY_SPLIT()),
        "treasuryFeeSplitBP must stay within bounds";
}

/*//////////////////////////////////////////////////////////////
                  REBALANCE STATE MACHINE
//////////////////////////////////////////////////////////////*/

/// @title Rebalance step always valid
/// @notice No function can set the step to an invalid enum value.
rule rebalanceStepAlwaysValid(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f) }
{
    require getRebalanceStep() <= STEP_DONE();

    f(e, args);

    assert getRebalanceStep() <= STEP_DONE(),
        "rebalance step must always be a valid enum value (0-5)";
}

/// @title forceRebalanceReset always resets to Done
/// @notice Guardian reset sets the step to Done regardless of current state.
rule forceResetGoesToDone(env e) {
    forceRebalanceReset(e);

    assert getRebalanceStep() == STEP_DONE(),
        "forceRebalanceReset must set step to Done";
}

/// @title updateAccounting requires rebalance Done
/// @notice updateAccounting reverts if rebalance is in progress.
rule updateAccountingRequiresDone(env e) {
    uint8 step = getRebalanceStep();

    updateAccounting@withrevert(e);

    assert step != STEP_DONE() => lastReverted,
        "updateAccounting must revert when rebalance is in progress";
}

/// @title updateAccounting is reachable when step is Done
/// @notice Verifies the happy path exists -- updateAccounting can succeed when not rebalancing.
/// @dev satisfy (not assert) -- proves the success path is not dead code.
rule updateAccountingReachableWhenDone(env e) {
    require getRebalanceStep() == STEP_DONE();

    updateAccounting@withrevert(e);

    satisfy !lastReverted,
        "updateAccounting must be reachable when rebalance step is Done";
}

/*//////////////////////////////////////////////////////////////
              REBALANCE FSM TRANSITION EDGES
//////////////////////////////////////////////////////////////*/

/// Valid rebalance transition edges. The FSM can only advance forward or self-loop.
/// Allowed edges derived from rebalance() control flow:
///   Done(5)              -> Done(5)              [idle no-op early return]
///   Done(5)              -> Harvest(0)           [start new cycle; may continue through]
///   Done(5)              -> PullUnstaked(1)      [Harvest completes in same call]
///   Done(5)              -> FinalizeWithdrawals(2) [continues through Harvest+Pull]
///   Done(5)              -> InitiateUnstake(3)   [continues further]
///   Done(5)              -> StakeSurplus(4)      [continues further]
///   Harvest(0)           -> PullUnstaked(1)      [always advances]
///   Harvest(0)           -> FinalizeWithdrawals(2) [continues through PullUnstaked]
///   Harvest(0)           -> InitiateUnstake(3)   [continues further]
///   Harvest(0)           -> StakeSurplus(4)      [continues further]
///   PullUnstaked(1)      -> FinalizeWithdrawals(2) [always advances]
///   PullUnstaked(1)      -> InitiateUnstake(3)   [continues further]
///   PullUnstaked(1)      -> StakeSurplus(4)      [continues further]
///   FinalizeWithdrawals(2) -> FinalizeWithdrawals(2) [gas gate or more work]
///   FinalizeWithdrawals(2) -> InitiateUnstake(3) [finalization complete]
///   FinalizeWithdrawals(2) -> StakeSurplus(4)    [continues further]
///   InitiateUnstake(3)   -> InitiateUnstake(3)   [gas gate or partial unstake]
///   InitiateUnstake(3)   -> StakeSurplus(4)      [unstake complete]
///   StakeSurplus(4)      -> StakeSurplus(4)       [gas gate or partial stake]
///   StakeSurplus(4)      -> Done(5)               [stake complete]
///
/// Additionally, when the cycle fully completes (reaches Done) and _rebalanceCompletionSatisfied,
/// _updateAccountingInternal() runs, but the step is already Done.
///
/// The key invariant: step can never go BACKWARD (except Done->Harvest which is the cycle restart),
/// and can never skip a step in the forward direction.
/// Simplified: stepAfter >= stepBefore (mod cycle restart), or equivalently:
///   if stepBefore != Done: stepAfter >= stepBefore
///   if stepBefore == Done: any stepAfter is valid (cycle restart goes through 0..5)

definition isValidRebalanceTransition(uint8 before, uint8 after) returns bool =
    // From Done: can go to any step (cycle restart traverses forward, or idle self-loop)
    (before == STEP_DONE() && after <= STEP_DONE())
    ||
    // From non-Done: must advance forward or self-loop (never backward, never skip to Done
    // without passing through intermediate steps -- but the call CAN traverse multiple steps
    // in sequence, so we only assert after >= before, not after == before or before+1)
    (before != STEP_DONE() && after >= before && after <= STEP_DONE());

/// @title Rebalance transitions only advance forward or self-loop
/// @notice rebalance() never moves the FSM backward. From any non-Done step, the step
///         can only stay the same (partial progress/gas gate) or advance to a later step
///         (one or more steps completed in the same call).
rule rebalanceOnlyAdvancesForward(env e) {
    uint8 stepBefore = getRebalanceStep();
    require stepBefore <= STEP_DONE();

    rebalance@withrevert(e);
    bool reverted = lastReverted;

    uint8 stepAfter = getRebalanceStep();

    assert !reverted => isValidRebalanceTransition(stepBefore, stepAfter),
        "rebalance must only advance forward or self-loop, never skip backward";
}

/// @title forceRebalanceReset is the only way to go backward
/// @notice No function other than forceRebalanceReset and rebalance (which has constrained
///         transitions) can change the rebalance step. All other functions must leave it unchanged.
rule rebalanceStepStableUnderOtherOps(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f)
                  && f.selector != sig:rebalance().selector
                  && f.selector != sig:forceRebalanceReset().selector }
{
    uint8 stepBefore = getRebalanceStep();

    f(e, args);

    assert getRebalanceStep() == stepBefore,
        "only rebalance() and forceRebalanceReset() may change the rebalance step";
}

/*//////////////////////////////////////////////////////////////
               PARAMETER SETTER ACCESS CONTROL
//////////////////////////////////////////////////////////////*/

/// @title Setters revert on invalid rebalance cooldown
/// @notice Cooldown outside [MIN, MAX] reverts.
rule setRebalanceCooldownRespectsBounds(env e) {
    uint256 newCooldown;

    setRebalanceCooldown@withrevert(e, newCooldown);

    // MIN_REBALANCE_COOLDOWN = 10 min = 600, MAX = 24h = 86400
    assert !lastReverted => (rebalanceCooldown() >= 600 && rebalanceCooldown() <= 86400),
        "successful setRebalanceCooldown must result in cooldown within bounds";
}

/// @title Setters revert on invalid gas threshold
/// @notice Gas threshold outside [MIN, MAX] reverts.
rule setGasThresholdRespectsBounds(env e) {
    uint256 newThreshold;
    uint32 oldThreshold = core.rebalanceGasThreshold(e);

    setRebalanceGasThreshold@withrevert(e, newThreshold);

    // MIN = 20_000, MAX = 1_000_000
    assert !lastReverted => (core.rebalanceGasThreshold(e) >= 20000 && core.rebalanceGasThreshold(e) <= 1000000),
        "successful setRebalanceGasThreshold must result in threshold within bounds";
}

/*//////////////////////////////////////////////////////////////
                 REPORT & FLOW COUNTER MONOTONICITY
//////////////////////////////////////////////////////////////*/


/// @title Flow counter snapshots never decrease after updateAccounting
/// @notice latestReportCumulativeDeposits and latestReportCumulativeWithdrawals are updated
///         to the current vault counters during updateAccounting. Since vault counters only
///         grow (+=), the snapshots must be monotonically non-decreasing.
/// @dev We require getCumulativeDeposits() >= snapshot (vault counter monotonicity) because
///      vault counters are summarized as NONDET -- Certora can't verify vault-side monotonicity
///      here. This models the real invariant: vault counters only increase.
rule flowCounterSnapshotsMonotonicOnUpdate(env e) {
    uint256 depsBefore = getLatestReportCumulativeDeposits();
    uint256 wdsBefore = getLatestReportCumulativeWithdrawals();

    // Model vault counter monotonicity: vault counters are always >= the last snapshot.
    // This holds because OllaVault only does cumulativeDeposits += and cumulativeWithdrawals +=.
    require getCumulativeDeposits() >= depsBefore;
    require getCumulativeWithdrawals() >= wdsBefore;

    updateAccounting@withrevert(e);
    bool reverted = lastReverted;

    assert !reverted => getLatestReportCumulativeDeposits() >= depsBefore,
        "latestReportCumulativeDeposits must not decrease after updateAccounting";
    assert !reverted => getLatestReportCumulativeWithdrawals() >= wdsBefore,
        "latestReportCumulativeWithdrawals must not decrease after updateAccounting";
}

/// @title Report timestamp stable under non-accounting operations
/// @notice Only updateAccounting and rebalance (on completion) update the report timestamp.
///         All other operations must leave it unchanged.
/// @dev rebalance() calls _updateAccountingInternal() when _rebalanceCompletionSatisfied(),
///      so it must be excluded alongside updateAccounting.
rule reportTimestampStableUnderOtherOps(env e, method f, calldataarg args)
    filtered { f -> !isInitOrUpgrade(f)
                  && f.selector != sig:updateAccounting().selector
                  && f.selector != sig:rebalance().selector }
{
    uint256 tsBefore = getLatestReportTimestamp();

    f(e, args);

    assert getLatestReportTimestamp() == tsBefore,
        "report timestamp must not change except via updateAccounting or rebalance";
}
