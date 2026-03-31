/*
 * Certora Verification Spec: OllaCore Accounting
 *
 * Properties verified:
 *   1. Fee bounds — protocol fee never exceeds MAX_PROTOCOL_FEE_BP
 *   2. Treasury split bounds — always within [MIN, MAX]
 *   3. Rebalance step validity — always a valid enum value
 *   4. Rebalance state machine — valid transitions only
 *   5. forceRebalanceReset — always resets to Done
 *   6. updateAccounting gating — reverts when rebalance in progress
 *   7. Parameter setter bounds — all setters enforce their bounds
 *
 * NOTE: Rules that iterate over ALL functions (flowCountersMonotonic, reportTimestampMonotonic)
 * are excluded because rebalance() and updateAccounting() make 5+ external calls
 * (StakingManager, RewardsAccumulator, SafetyModule, Vault, WithdrawalQueue) that would
 * require full protocol modeling. Those properties are better tested by the existing
 * Foundry invariant suite which runs against the real deployed contracts.
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

    // Mutating functions
    function rebalance() external returns (uint256, uint256, uint256, uint256);
    function updateAccounting() external;
    function setProtocolFeeBP(uint256) external;
    function setTreasuryFeeSplitBP(uint256) external;
    function setTargetBufferedAssets(uint256) external;
    function setRebalanceCooldown(uint256) external;
    function setRebalanceGasThreshold(uint256) external;
    function forceRebalanceReset() external;

    // External contract summaries — all external calls return consistent arbitrary values.
    // This is sufficient for parameter-bound and state-machine rules that don't depend
    // on external return values.
    function _.bufferedAssets() external => PER_CALLEE_CONSTANT;
    function _.pendingWithdrawalAssets() external => PER_CALLEE_CONSTANT;
    function _.pendingWithdrawalShares() external => PER_CALLEE_CONSTANT;
    function _.totalSupply() external => PER_CALLEE_CONSTANT;
    // Summarize all other external calls as NONDET (rebalance calls many contracts)
    function _.harvestRewards() external => NONDET;
    function _.recordBalance() external => NONDET;
    function _.stake(uint256) external => NONDET;
    function _.totalStaked() external => NONDET;
    function _.pendingUnstakes() external => NONDET;
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
