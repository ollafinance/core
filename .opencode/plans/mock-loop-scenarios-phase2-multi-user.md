# Phase 2: Multi-User & Lifecycle Scenarios

**Scope**: Add multi-user deposit, partial withdrawal, and full deposit-after-withdraw lifecycle scenarios. These test share accounting fairness, exchange rate consistency, and the protocol's behavior with concurrent users.

## Prerequisites

- Existing mock-loop running successfully
- At least 3 Anvil accounts available (accounts 1-3 as users)

---

## Scenario 1: `multi-user-deposit`

### Purpose

Deposit from multiple users at different ticks to test share accounting with varying exchange rates. Validates that no user is advantaged/disadvantaged by deposit timing relative to reward accrual.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface MultiUserDepositScenario extends BaseScenario {
     type: "multi-user-deposit";
     users: Array<{
       privateKey: `0x${string}`;
       amount: string;
       depositTick: number; // which tick this user deposits on
     }>;
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/multi-user-deposit.ts`**:
   ```typescript
   export async function executeMultiUserDeposit(
     config: MultiUserDepositScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState,
     tick: number
   ): Promise<ActionResult>
   ```
   - Filter `config.users` to find users scheduled for the current tick
   - For each user due this tick:
     - Create wallet from private key
     - Mint tokens to user
     - Approve OllaCore
     - Call `deposit(amount, userAddress, 0)`
     - Record exchange rate at deposit time
   - Track all deposits in `scenarioState.deposits[]`
   - Return: `{ deposited: [{ user, amount, exchangeRate, shares }] }`

3. **Extend state reader in `lib/state.ts`**:
   - Ensure `readFullState()` picks up all user addresses from multi-user scenarios
   - Users are already extracted from scenarios with `privateKey` fields, but multi-user has nested `users[]` array — add extraction logic:
   ```typescript
   if (scenario.type === "multi-user-deposit") {
     for (const user of scenario.users) {
       userKeys.add(user.privateKey);
     }
   }
   ```

4. **Add default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "multi-user-deposit",
     enabled: false,
     users: [
       { privateKey: ANVIL_ACCOUNTS[1].privateKey, amount: "100000000000000000000000", depositTick: 1 },
       { privateKey: ANVIL_ACCOUNTS[2].privateKey, amount: "150000000000000000000000", depositTick: 5 },
       { privateKey: ANVIL_ACCOUNTS[3].privateKey, amount: "50000000000000000000000", depositTick: 10 },
     ],
     shouldRun: (state, tick) => [1, 5, 10].includes(tick),
   }
   ```

### Test Cases

- [ ] Each user receives shares proportional to their deposit at the current exchange rate
- [ ] Users depositing later (after rewards accrue) receive fewer shares per token
- [ ] Total stAztec supply equals sum of all user share balances
- [ ] State reader correctly tracks all user balances independently
- [ ] Exchange rate is consistent across all deposits within the same tick

---

## Scenario 2: `partial-withdraw`

### Purpose

Test partial withdrawal — redeeming a fraction of shares instead of the full balance. Validates that the user retains remaining shares and continues earning rewards on them.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface PartialWithdrawScenario extends BaseScenario {
     type: "partial-withdraw";
     privateKey: `0x${string}`;
     withdrawPct: number; // percentage of shares to withdraw (e.g., 25, 50)
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/partial-withdraw.ts`**:
   ```typescript
   export async function executePartialWithdraw(
     config: PartialWithdrawScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState
   ): Promise<ActionResult>
   ```
   - Get user's stAztec balance
   - Calculate withdraw amount: `(balance * withdrawPct) / 100`
   - If amount > 0: Call `requestRedeem(withdrawShares, userAddress)`
   - Record remaining balance
   - Return: `{ user, totalShares, withdrawnShares, remainingShares, withdrawPct }`

3. **Add default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "partial-withdraw",
     enabled: false,
     privateKey: ANVIL_ACCOUNTS[1].privateKey,
     withdrawPct: 50,
     shouldRun: (state, tick) => tick === 20,
   }
   ```

### Test Cases

- [ ] User's stAztec balance decreases by exactly `withdrawPct`%
- [ ] Withdrawal request is created with correct share amount
- [ ] Remaining shares continue to earn rewards in subsequent ticks
- [ ] Multiple partial withdrawals can be executed sequentially
- [ ] Claiming partial withdrawal returns correct asset amount at locked rate

---

## Scenario 3: `deposit-after-withdraw`

### Purpose

Test the full lifecycle: deposit → earn rewards → partial withdraw → deposit again → full withdraw → claim. Validates exchange rate consistency across multiple operations by the same user.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface DepositAfterWithdrawScenario extends BaseScenario {
     type: "deposit-after-withdraw";
     privateKey: `0x${string}`;
     initialDeposit: string;
     secondDeposit: string;
     schedule: {
       depositTick: number;
       partialWithdrawTick: number;
       secondDepositTick: number;
       fullWithdrawTick: number;
       claimTick: number;
     };
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/deposit-after-withdraw.ts`**:
   ```typescript
   export async function executeDepositAfterWithdraw(
     config: DepositAfterWithdrawScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState,
     tick: number
   ): Promise<ActionResult>
   ```
   - Use `scenarioState.phase` to track lifecycle stage
   - **Phase "deposit"** (depositTick): Mint + approve + deposit `initialDeposit`
   - **Phase "partial-withdraw"** (partialWithdrawTick): Redeem 50% of shares
   - **Phase "second-deposit"** (secondDepositTick): Mint + approve + deposit `secondDeposit`
   - **Phase "full-withdraw"** (fullWithdrawTick): Redeem all remaining shares
   - **Phase "claim"** (claimTick): Claim all finalized withdrawal requests
   - At each phase, record exchange rate and balances
   - Return phase-specific result with full audit trail in `scenarioState`

3. **Add default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "deposit-after-withdraw",
     enabled: false,
     privateKey: ANVIL_ACCOUNTS[2].privateKey,
     initialDeposit: "100000000000000000000000", // 100k
     secondDeposit: "50000000000000000000000",   // 50k
     schedule: {
       depositTick: 1,
       partialWithdrawTick: 20,
       secondDepositTick: 35,
       fullWithdrawTick: 50,
       claimTick: 70,
     },
     shouldRun: (state, tick) => [1, 20, 35, 50, 70].includes(tick),
   }
   ```

### Test Cases

- [ ] Initial deposit receives correct shares at initial exchange rate
- [ ] Partial withdrawal creates request for exactly 50% of shares
- [ ] Second deposit receives shares at the (now higher) exchange rate
- [ ] Full withdrawal redeems all remaining shares (from both deposits)
- [ ] Claimed assets reflect reward accrual across the full lifecycle
- [ ] Exchange rate is monotonically non-decreasing throughout (no rewards leakage)
- [ ] User's final asset balance > initial deposit (net positive from rewards)

---

## Shared Modifications

### `lib/state.ts` changes
- Update user key extraction to handle `multi-user-deposit` nested `users[]` array
- Update user key extraction to handle `deposit-after-withdraw` `privateKey`

### `index.ts` changes
- Add 3 new cases to `executeScenario()` switch
- Pass `tick` number to scenarios that need tick-aware execution (`multi-user-deposit`, `deposit-after-withdraw`)

### `config.ts` changes
- Add 3 new scenario entries (all `enabled: false`)
- Import additional Anvil account private keys if needed

## Acceptance Criteria

- [ ] Multi-user deposits produce correct share allocations at varying exchange rates
- [ ] Partial withdrawal leaves correct remaining balance
- [ ] Full lifecycle scenario completes all 5 phases without errors
- [ ] State reader tracks all users from all scenario types
- [ ] No interference between multi-user scenario and existing single-user scenarios

## Verification

```bash
# Run multi-user profile (replaces default single-user scenarios)
npx tsx mock-loop/index.ts --config mock-loop/configs/multi-user.ts --once

# Run lifecycle scenario (requires 70+ ticks)
npx tsx mock-loop/index.ts --config mock-loop/configs/lifecycle.ts
```
