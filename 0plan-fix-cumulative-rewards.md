# Refactoring Plan: Fix Cumulative Rewards Calculation

## Bug Summary

**Core Problem**: `StakingManager.harvestRewards()` calls `rollup.claimSequencerRewards()` which is **permissionless** on Aztec. Anyone can harvest rewards directly, causing:

1. Rewards arrive at `RewardsVault` without OllaCore knowing the exact amount
2. Current system uses `expectedRewards` parameter with balance checks that will fail
3. Direct transfers to RewardsVault are treated as "excess" rather than legitimate rewards

## Current Flow (Buggy)

```
1. Operator calls OllaCore.harvestRewards()
   └── Calls StakingManager.harvestRewards()
       └── Calls Rollup.claimSequencerRewards(rewardsVault)
           └── Rewards tokens are transferred to RewardsVault
   └── Receives harvested amount (from StakingManager)
   └── Adds to cumulativeRewards (using EXPECTED amount)
   └── Calls rewardsVault.recordRewards(harvested)
       └── Vault checks: balance == previous + expected
       └── Fails if permissionless harvest happened or direct transfer occurred
```

## Refactoring Plan

### Phase 1: Interface Changes

#### 1. IRewardsVault.sol
- Remove `ExcessFundsDetected` event
- Update `recordRewards()` signature: remove parameter, add `returns (uint256 rewardsDelta)`
- Remove `RewardsVault__BalanceMismatch` error
- Update `RewardsRecorded` event docs to indicate it emits delta

#### 2. IOllaCore.sol
- Keep `RewardsDelta` event (already added in TODO)
- Mark `RewardsHarvested` event as deprecated for removal
- Update `harvestRewards()` return docs

### Phase 2: Implementation Changes

#### 3. RewardsVault.sol - `recordRewards()` refactor

```solidity
function recordRewards() external override onlyCore nonReentrant returns (uint256 rewardsDelta) {
    uint256 previousAmount = latestRecordedRewardsAmount;
    uint256 currentTokenBalance = rewardsToken.balanceOf(address(this));
    rewardsDelta = currentTokenBalance - previousAmount;
    latestRecordedRewardsAmount = currentTokenBalance;
    emit RewardsRecorded(rewardsDelta);
}
```

Key changes:
- No parameter, no reverts (handles permissionless harvests gracefully)
- Returns delta (current - previous)
- All balance increases = rewards (no "excess" concept)
- Emits only the delta amount

#### 4. OllaCore.sol - `harvestRewards()` refactor

```solidity
function harvestRewards()
    external
    override
    onlyRole(OPERATOR_ROLE)
    whenNotPaused
    nonReentrant
    returns (uint256 rewardsDelta)
{
    // Trigger the actual claiming on the rollup
    _modules.stakingManager.harvestRewards();
    
    // Get the actual delta from RewardsVault
    rewardsDelta = _modules.rewardsVault.recordRewards();
    
    if (rewardsDelta != 0) {
        _accountingState.cumulativeRewards += rewardsDelta;
    }
    
    // No event emission - StakingManager and RewardsVault emit their own
    return rewardsDelta;
}
```

Key changes:
- Ignores return value from StakingManager (just triggers claiming)
- Uses delta from RewardsVault (actual received, not expected)
- No event emission (other contracts emit sufficient events)
- Returns delta only

### Phase 3: Test Files Requiring Updates

| Test File | Specific Tests/Rationale |
|-----------|-------------------------|
| **RewardsVault.t.sol** | `test_PostReceiveFundsHook_RecordsRewardsNoExcess` - update to check returned delta<br>`test_PostReceiveFundsHook_RecordsRewardsAndDetectsExcessFunds` - REMOVE (no excess concept)<br>`test_RevertWhen_PostReceiveFundsHook_BalanceDecreasedSinceLastRecord` - update (should handle gracefully or remove revert)<br>`test_WithdrawToCore_TransfersAndUpdatesAccounting` - update recordRewards calls<br>`test_WithdrawToCore_AccumulatesOverMultipleHarvests` - update recordRewards calls |
| **OllaCore.t.sol** | `test_HarvestRewards_CallsRecordRewardsWithCorrectAmount` - update to verify delta, remove param<br>`test_UpdateAccountingIncludesRewardsAndSlashing` - update cumulativeRewards assertions<br>`test_UpdateAccounting_RewardDeltaUsesCumulativeAndClaimableRewards` - verify new flow<br>All tests checking `RewardsHarvested` event - REMOVE event checks |
| **StakingManager.t.sol** | `test_HarvestRewards_*` - verify harvest flow still works (returns will still be same)<br>Mock in tests will need updating |
| **MockRewardsVault.sol** | Update `recordRewards()` to match new interface: no parameter, return delta |
| **OllaCore.reentrancy.t.sol** | Update `MockHarvestStakingManager` and reentrancy tests<br>Update mock `harvestRewards()` return handling |
| **StakingManager.invariant.t.sol** | Review `ghost_totalHarvested` tracking - may need to change how ghost var is updated<br>Handler's `harvestRewards` function logic may need updating |

### Phase 4: Mock Updates

#### MockRewardsVault.sol
```solidity
function recordRewards() external override returns (uint256 rewardsDelta) {
    if (_hookShouldFail) revert MockRewardsVault__HookFailed();
    
    uint256 currentBalance = REWARDS_TOKEN.balanceOf(address(this));
    rewardsDelta = currentBalance - _latestRecordedRewardsAmount;
    _totalReceived += rewardsDelta;
    _latestRecordedRewardsAmount = currentBalance;
    
    emit RewardsRecorded(rewardsDelta);
    return rewardsDelta;
}
```

## Key Benefits

1. **Fixes permissionless bug**: No longer relies on expected amounts - uses actual balance delta
2. **Handles direct transfers**: All balance increases count as rewards, no special "excess" handling needed
3. **No reverts**: Gracefully handles any balance changes (including permissionless harvests)
4. **Simpler logic**: Delta-based accounting is more robust and easier to reason about
5. **Accurate accounting**: Records actual received amount, not an expected amount that may be wrong
6. **Event consistency**: Removes redundant events, lets each contract emit its own events

## Implementation Order

1. Update interfaces (IRewardsVault.sol, IOllaCore.sol)
2. Update RewardsVault.sol implementation
3. Update OllaCore.sol implementation
4. Update MockRewardsVault.sol
5. Update all test files
6. Run full test suite to verify

## Files to Modify

- `contracts/src/core/interfaces/IRewardsVault.sol`
- `contracts/src/core/interfaces/IOllaCore.sol`
- `contracts/src/core/RewardsVault.sol`
- `contracts/src/core/OllaCore.sol`
- `contracts/src/core/mocks/MockRewardsVault.sol`

## Test Files to Update

- `contracts/test/core/RewardsVault.t.sol`
- `contracts/test/core/OllaCore.t.sol`
- `contracts/test/core/OllaCore.reentrancy.t.sol`
- `contracts/test/staking/StakingManager.t.sol`
- `contracts/test/staking/StakingManager.invariant.t.sol`
