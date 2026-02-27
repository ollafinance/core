# Phase 4: Invariant Checking & Infrastructure

**Scope**: Add a per-tick invariant checker, accounting timestamp boundary testing, refactor user-claim to use dynamic finalization detection, and create config profiles for different test modes.

## Prerequisites

- Phase 1 complete (invariant checker needs to validate slashing state)
- Phase 2 complete (invariant checker needs to validate multi-user balances)

---

## Scenario 1: `invariant-checker`

### Purpose

Run every tick to validate protocol invariants. Catches state drift, accounting bugs, and consistency violations that individual scenarios might miss.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface InvariantCheckerScenario extends BaseScenario {
     type: "invariant-checker";
     invariants: {
       accountingBalance: boolean;      // totalAssets ≈ buffered + staked + claimable
       shareTotalSupply: boolean;        // sum(user stAztec) ≤ totalSupply
       exchangeRateMonotonic: boolean;   // rate never decreases (unless slashing enabled)
       withdrawalQueueBounded: boolean;  // pendingAssets ≤ bufferedAssets
       noNegativeBalances: boolean;      // all balances ≥ 0
     };
     toleranceBps?: number; // rounding tolerance in bps (default: 1 = 0.01%)
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/invariant-checker.ts`**:
   ```typescript
   interface InvariantResult {
     name: string;
     passed: boolean;
     expected: string;
     actual: string;
     details?: string;
   }

   export async function executeInvariantChecker(
     config: InvariantCheckerScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState
   ): Promise<ActionResult>
   ```

   **Invariant implementations**:

   a. **Accounting Balance**:
   ```typescript
   // totalAssets ≈ bufferedAssets + stakedPrincipal + claimableRewards
   const expected = bufferedAssets + stakedPrincipal + claimableRewards;
   const actual = totalAssets;
   const withinTolerance = abs(expected - actual) <= (expected * toleranceBps) / 10_000n;
   ```

   b. **Share Total Supply**:
   ```typescript
   // Read stAztec.totalSupply()
   // Sum all tracked user stAztec balances
   // Verify: sumUserBalances <= totalSupply (other holders may exist)
   ```

   c. **Exchange Rate Monotonic**:
   ```typescript
   // Compare current exchange rate to scenarioState.lastExchangeRate
   // Only assert non-decreasing if no slashing scenarios are enabled
   // If slashing: assert rate decreased by at most the slash amount
   if (!runState.slashingOccurred) {
     assert(currentRate >= lastRate);
   }
   scenarioState.lastExchangeRate = currentRate;
   ```

   d. **Withdrawal Queue Bounded**:
   ```typescript
   // totalPendingAssets should not exceed available liquidity
   // This is a soft check — pending can temporarily exceed buffered during rebalance
   ```

   e. **No Negative Balances**:
   ```typescript
   // All BigInt balance values in TickState should be >= 0
   // Walk the state tree and check every numeric field
   ```

   - Collect all results, return: `{ invariants: InvariantResult[], allPassed: boolean }`
   - If any invariant fails: log detailed error but don't crash (report as warning)

3. **Add default config in `config.ts`** (enabled by default — this is observational):
   ```typescript
   {
     type: "invariant-checker",
     enabled: true,
     invariants: {
       accountingBalance: true,
       shareTotalSupply: true,
       exchangeRateMonotonic: true,
       withdrawalQueueBounded: true,
       noNegativeBalances: true,
     },
     toleranceBps: 1,
     shouldRun: (state, tick) => true, // every tick
   }
   ```

### Test Cases

- [ ] All invariants pass on default happy-path run
- [ ] Accounting balance invariant catches artificial imbalances
- [ ] Exchange rate monotonic invariant detects unexpected decreases
- [ ] Individual invariants can be toggled on/off
- [ ] Tolerance parameter prevents false positives from rounding
- [ ] Invariant failures are logged as warnings (not hard errors)

---

## Scenario 2: `accounting-timestamp`

### Purpose

Test boundary conditions of `setLatestAccountingTimestamp` (commit `ee8ce20` rejects future timestamps).

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface AccountingTimestampScenario extends BaseScenario {
     type: "accounting-timestamp";
     action: "set-current" | "set-past" | "set-future";
     offsetSeconds?: number; // offset from current block timestamp
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/accounting-timestamp.ts`**:
   ```typescript
   export async function executeAccountingTimestamp(
     config: AccountingTimestampScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState
   ): Promise<ActionResult>
   ```
   - Read current block timestamp
   - **"set-current"**: Call with `block.timestamp` — should succeed
   - **"set-past"**: Call with `block.timestamp - offsetSeconds` — should succeed
   - **"set-future"**: Call with `block.timestamp + offsetSeconds` — should revert
   - Catch revert on future timestamp, verify error selector
   - Return: `{ action, timestamp, blockTimestamp, success, revertReason? }`

3. **Add default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "accounting-timestamp",
     enabled: false,
     action: "set-future",
     offsetSeconds: 3600, // 1 hour in the future
     shouldRun: (state, tick) => tick === 5,
   }
   ```

### Test Cases

- [ ] Current timestamp is accepted
- [ ] Past timestamp is accepted
- [ ] Future timestamp is rejected with expected error
- [ ] Protocol continues normally after rejected timestamp
- [ ] Offset parameter works correctly for both past and future

---

## Infrastructure: Dynamic Finalization Refactor

### Purpose

Replace the hardcoded tick 43 in `user-claim` config with actual on-chain finalization checking.

### Implementation Steps

1. **Modify `lib/scenarios/user-claim.ts`**:
   - Before attempting claims, check `isFinalized(requestId)` for each active request
   - Only attempt to claim finalized requests
   - Log finalization status for unfinalized requests
   - This replaces the catch-and-ignore pattern with explicit finalization awareness

   ```typescript
   // Before (current):
   try {
     await claimRequestById(requestId);
     claimed++;
   } catch {
     failed++;
   }

   // After (refactored):
   const finalized = await withdrawalQueue.read.isFinalized([requestId]);
   if (finalized) {
     await claimRequestById(requestId);
     claimed++;
   } else {
     pending++;
   }
   ```

2. **Update `config.ts`**:
   - Change `user-claim` schedule from `tick >= 43` to `tick >= withdrawTick + 2`
   - Or better: run every tick after the withdraw tick and let the finalization check handle timing:
   ```typescript
   shouldRun: (state, tick) => tick > 25, // runs after withdraw, polls finalization
   ```

### Test Cases

- [ ] Claims are only attempted for finalized requests
- [ ] Unfinalized requests are logged as pending (not errors)
- [ ] No behavioral change for the happy path
- [ ] Works correctly regardless of tick timing

---

## Infrastructure: Config Profiles

### Purpose

Create preset configuration files for different test modes.

### Implementation Steps

1. **Create `mock-loop/configs/` directory**

2. **Create `mock-loop/configs/stress-test.ts`**:
   ```typescript
   // All scenarios enabled
   // 3 users depositing at different ticks
   // Rapid rebalance (every 5 ticks instead of 10)
   // Short interval (500ms)
   // 100+ tick run
   ```

3. **Create `mock-loop/configs/adversarial.ts`**:
   ```typescript
   // Slashing enabled at tick 20
   // Negative rewards period at tick 22
   // External exit at tick 15
   // Governance rejection at tick 30
   // Withdraw-before-finalization enabled
   // Gas threshold boundary testing
   // Invariant checker on every tick
   ```

4. **Create `mock-loop/configs/happy-path.ts`**:
   ```typescript
   // Current default config extracted to its own file
   // Single user, standard scheduling
   // Used as baseline comparison
   ```

### Test Cases

- [ ] Each config profile loads and runs without import errors
- [ ] Stress test config exercises all multi-user scenarios
- [ ] Adversarial config triggers expected errors/reverts gracefully
- [ ] Happy path config produces identical results to current default

---

## Shared Modifications

### `index.ts` changes
- Add 2 new cases to `executeScenario()` switch (invariant-checker, accounting-timestamp)
- The invariant checker should run LAST in the scenario list (after all state changes)

### `config.ts` changes
- Add invariant-checker (enabled by default, runs every tick)
- Add accounting-timestamp (disabled by default)
- Refactor user-claim scheduling to use dynamic finalization

### `types.ts` changes
- Add 2 new interfaces, update `ScenarioConfig` union
- Add `slashingOccurred` flag to `RunState` (set by slashing scenario in Phase 1)

### `lib/state.ts` changes
- Add `stAztecTotalSupply` to `TickState` (needed for share total supply invariant)

## Acceptance Criteria

- [ ] Invariant checker runs every tick and passes on happy-path config
- [ ] Accounting timestamp scenario correctly validates boundary conditions
- [ ] Dynamic finalization refactor removes hardcoded tick dependency
- [ ] All 3 config profiles load and execute successfully
- [ ] Invariant checker catches injected accounting errors (manual validation)

## Verification

```bash
# Run with invariant checker enabled (default)
npx tsx mock-loop/index.ts --once

# Run stress test profile
npx tsx mock-loop/index.ts --config mock-loop/configs/stress-test.ts

# Run adversarial profile
npx tsx mock-loop/index.ts --config mock-loop/configs/adversarial.ts --until-error

# Compare happy-path output to existing baseline
npx tsx mock-loop/index.ts --config mock-loop/configs/happy-path.ts --once
diff <(cat mock-loop/runs/baseline/tick-*.json) <(cat mock-loop/runs/latest/tick-*.json)
```
