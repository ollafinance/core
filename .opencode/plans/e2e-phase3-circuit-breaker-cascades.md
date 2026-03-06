# Phase 3: Circuit Breaker Cascades

**Risk**: High — the SafetyModule contains three independent circuit breakers (rate drop, queue ratio, accounting liveness) that auto-pause the module on trigger. When one fires, it blocks all deposit/redeem operations. The cascade behavior (multiple breakers firing in sequence) and state recovery after unpause need validation.

## Scope

Validate that:
- Each circuit breaker fires at the correct threshold
- Auto-pause blocks all user operations (deposit, requestRedeem, instantRedeem)
- Multiple breakers can fire in sequence after guardian unpause
- Rebalance state machine is not corrupted by a breaker firing mid-cycle
- Guardian unpause restores full protocol functionality
- Accounting remains consistent through breaker → pause → unpause → rebalance

## Prerequisites

- OllaCore, OllaVault, WithdrawalQueue, StAztec (real, proxied)
- SafetyModule (real, non-upgradeable) — this is the contract under test
- MockAccountingStakingManager (to simulate slashing and rewards)
- MockRewardsAccumulator

## Implementation Steps

### 1. Create test contract with real SafetyModule

```solidity
// contracts/test/e2e/CircuitBreakerCascades.e2e.t.sol

contract CircuitBreakerCascadesE2ETest is Test {
    event CircuitBreakerTriggered(ISafetyModule.BreakerReason reason);
    event Paused();
    event Unpaused();

    // Full stack with REAL SafetyModule
    // SafetyModule constructor params control thresholds:
    //   SafetyModule(admin, guardian, core, vault, depositCap, minRateDropBps, maxQueueRatioBps, maxAccountingDelay)
}
```

### 2. SafetyModule threshold configuration

```solidity
// In setUp():
// Tunable thresholds for testing different breaker scenarios
safetyModule = new SafetyModule(
    admin,          // DEFAULT_ADMIN_ROLE
    guardian,       // GUARDIAN_ROLE
    address(core),  // CORE immutable
    address(vault), // VAULT immutable
    1_000_000e18,   // depositCap (high, not the focus)
    500,            // minRateDropBps = 5% — triggers on 5%+ rate drop
    5000,           // maxQueueRatioBps = 50% — triggers when queue > 50% of total
    1 days          // maxAccountingDelay = 1 day
);
```

### 3. Helper to verify paused state blocks operations

```solidity
function _assertAllOperationsBlocked() internal {
    // Deposit blocked
    asset.mint(bob, 10e18);
    vm.prank(bob);
    asset.approve(address(vault), 10e18);
    vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__SafetyModulePaused.selector));
    vm.prank(bob);
    vault.deposit(10e18, bob, 0);

    // Instant redeem blocked (if bob has shares)
    // requestRedeem blocked
}
```

## Test Cases

### Test 3a: `test_RateDropDuringRebalance_PausesProtocol`

```
Setup:
  1. alice deposits 100e18
  2. Full rebalance → stake 90e18 (targetBuffer = 10e18)
  3. Set minRateDropBps = 500 (5% threshold) via admin

Actions:
  4. Simulate slashing: stakingManager.setSlashingDelta(10e18) → 10% drop
     Also reduce totalStaked to reflect slashing
  5. Warp past cooldown, call rebalance

Assertions:
  - vm.expectEmit: CircuitBreakerTriggered(BreakerReason.RateDrop)
  - safetyModule.isPaused() == true
  - Deposit reverts with OllaVault__SafetyModulePaused
  - requestRedeem reverts with OllaVault__SafetyModulePaused
  - instantRedeem reverts with OllaVault__SafetyModulePaused

Recovery:
  6. vm.prank(guardian); safetyModule.unpause()
  7. safetyModule.isPaused() == false
  8. bob deposit succeeds
```

### Test 3b: `test_QueueRatioBreaker_DuringRebalance`

```
Setup:
  1. alice deposits 100e18
  2. Full rebalance (stake 90e18, buffer 10e18)
  3. Set maxQueueRatioBps = 4000 (40%) via admin

Actions:
  4. alice requests redeem of 50e18 shares (50% of total > 40% threshold)
  5. Warp past cooldown, call rebalance
     → FinalizeWithdrawals step calls checkQueueRatio(50e18, ~100e18)

Assertions:
  - vm.expectEmit: CircuitBreakerTriggered(BreakerReason.QueueRatio)
  - safetyModule.isPaused() == true
  - Further deposits blocked

Recovery:
  6. Guardian unpause
  7. Next rebalance should finalize withdrawals (reducing queue ratio)
```

### Test 3c: `test_AccountingLiveness_TriggersWhenStale`

```
Setup:
  1. alice deposits 100e18
  2. Full rebalance (sets lastAccountingTimestamp)
  3. maxAccountingDelay = 1 days

Actions:
  4. Warp 2 days forward (no rebalance in between)
  5. alice tries to deposit 10e18

Assertions:
  - The deposit flow calls checkAccountingLiveness()
  - vm.expectEmit: CircuitBreakerTriggered(BreakerReason.AccountingStale)
  - safetyModule.isPaused() == true
  - Deposit reverts

Recovery:
  6. Guardian unpause
  7. Rebalance completes → updates accounting timestamp
  8. Subsequent deposits succeed
```

### Test 3d: `test_CascadingBreakers_RateDropThenQueueRatio`

```
Setup:
  1. alice deposits 200e18
  2. Full rebalance (stake 190e18, buffer 10e18)
  3. Set minRateDropBps = 300 (3%), maxQueueRatioBps = 4000 (40%)

Actions:
  4. alice requests redeem 100e18 shares (50% > 40% threshold)
  5. Simulate slashing: 10e18 (5% drop > 3% threshold)
  6. Warp, call rebalance

Assertions — First breaker:
  - CircuitBreakerTriggered(BreakerReason.RateDrop) emitted
  - safetyModule.isPaused() == true
  - Rebalance may revert or complete depending on where checkRateDrop is called

Recovery + Second breaker:
  7. Guardian unpause
  8. Call rebalance again
  - FinalizeWithdrawals step calls checkQueueRatio(~100e18, ~190e18) → 52% > 40%
  - CircuitBreakerTriggered(BreakerReason.QueueRatio) emitted
  - safetyModule.isPaused() == true again

Final recovery:
  9. Guardian sets maxQueueRatioBps higher (e.g. 6000) via admin OR unpause
  10. Rebalance completes
  11. Protocol fully functional
```

### Test 3e: `test_BreakerDuringRebalance_DoesNotCorruptState`

```
Setup:
  1. alice deposits 100e18
  2. Full rebalance (stake 90e18, buffer 10e18)
  3. Set minRateDropBps = 100 (1%) — aggressive threshold

Actions:
  4. Simulate small slashing: 2e18 (2% drop > 1% threshold)
  5. Warp, call rebalance

Assertions — State consistency:
  - If rebalance reverts: rebalanceProgress().step is wherever it was before
  - If rebalance completes before breaker: step == Done
  - Either way, core accounting is self-consistent:
    * totalAssets() == stakedPrincipal + bufferedAssets (accounting for slashing)
    * exchangeRate() * totalSupply ~= totalAssets (within rounding)
  - No tokens stuck or lost

Recovery:
  6. Guardian unpause
  7. Next rebalance completes normally
  8. Exchange rate reflects slashing loss
  9. Alice can deposit, redeem normally
```

## Acceptance Criteria

- [ ] Rate drop breaker fires when rate decreases by >= `minRateDropBps`
- [ ] Queue ratio breaker fires when `pendingAssets / totalAssets >= maxQueueRatioBps`
- [ ] Accounting liveness breaker fires when `elapsed > maxAccountingDelay`
- [ ] Auto-pause blocks deposit, requestRedeem, instantRedeem with `OllaVault__SafetyModulePaused`
- [ ] Multiple breakers can fire in sequence (first fires, unpause, second fires)
- [ ] Guardian unpause restores all operations
- [ ] Rebalance state machine is not corrupted by breaker activation
- [ ] Core accounting invariants hold through breaker → pause → unpause → rebalance cycle

## Verification

```bash
forge test --match-contract CircuitBreakerCascadesE2ETest -vvv
```
