# Phase 3: Edge Cases & Error Path Scenarios

**Scope**: Add scenarios that exercise error paths, boundary conditions, and adversarial conditions. These validate that the protocol handles abnormal situations gracefully.

## Prerequisites

- Phase 1 complete (slashing scenario required for negative-rewards-period)
- Existing mock-loop running successfully

---

## Scenario 1: `negative-rewards-period`

### Purpose

Create a negative gross rewards period (slashing exceeds rewards) and validate that protocol accounting remains consistent and the event from commit `8d3b744` fires correctly.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface NegativeRewardsScenario extends BaseScenario {
     type: "negative-rewards-period";
     rewardRateBps: number;    // low reward rate to set
     slashAmountBps: number;   // high slash amount (must exceed rewards)
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/negative-rewards.ts`**:
   ```typescript
   export async function executeNegativeRewards(
     config: NegativeRewardsScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState
   ): Promise<ActionResult>
   ```
   - **Step 1**: Set a low reward rate on MockAztecRollup
   - **Step 2**: Trigger slashing that exceeds accrued rewards
   - **Step 3**: Call `updateAccounting()` on OllaCore
   - **Step 4**: Check transaction logs for negative gross rewards event
   - **Step 5**: Verify accounting state: `slashingDelta > rewardsDelta`
   - Return: `{ rewardsDelta, slashingDelta, netRewards, negativeEventEmitted }`

3. **Add default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "negative-rewards-period",
     enabled: false,
     rewardRateBps: 5,     // very low rewards
     slashAmountBps: 500,  // large slash
     shouldRun: (state, tick) => tick === 22,
   }
   ```

### Test Cases

- [ ] Negative net rewards period is created successfully
- [ ] Event is emitted (check tx receipt logs)
- [ ] Accounting state shows `slashingDelta > rewardsDelta`
- [ ] Exchange rate decreases
- [ ] Protocol continues to operate normally after negative period
- [ ] Subsequent positive rewards period restores normal operation

---

## Scenario 2: `gas-threshold`

### Purpose

Exercise the `setGasThreshold` function with valid and boundary values (commit `d1852bc`). Validate that the rebalance loop respects gas limits.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface GasThresholdScenario extends BaseScenario {
     type: "gas-threshold";
     action: "set-valid" | "set-boundary" | "set-invalid";
     gasThreshold?: bigint;
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/gas-threshold.ts`**:
   ```typescript
   export async function executeGasThreshold(
     config: GasThresholdScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState
   ): Promise<ActionResult>
   ```
   - **"set-valid"**: Call `setGasThreshold(reasonableValue)`, verify it succeeds
   - **"set-boundary"**: Call with upper bound value, verify it succeeds or reverts appropriately
   - **"set-invalid"**: Call with value above upper bound, verify it reverts
   - After setting valid threshold: trigger a rebalance and verify it respects the limit
   - Return: `{ action, gasThreshold, success, revertReason? }`

3. **Add default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "gas-threshold",
     enabled: false,
     action: "set-valid",
     gasThreshold: 500000n,
     shouldRun: (state, tick) => tick === 8,
   }
   ```

### Test Cases

- [ ] Valid gas threshold is accepted
- [ ] Upper bound value is handled correctly
- [ ] Values above upper bound revert
- [ ] Rebalance respects the configured gas threshold
- [ ] Gas threshold persists across ticks

---

## Scenario 3: `governance-rejection`

### Purpose

Test the governance transfer failure path — what happens when governance is proposed but never accepted, or when a second proposal supersedes the first.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface GovernanceRejectionScenario extends BaseScenario {
     type: "governance-rejection";
     action: "propose-no-accept" | "supersede-proposal";
     firstProposalKey: `0x${string}`;
     secondProposalKey?: `0x${string}`; // for "supersede-proposal"
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/governance-rejection.ts`**:
   ```typescript
   export async function executeGovernanceRejection(
     config: GovernanceRejectionScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState
   ): Promise<ActionResult>
   ```
   - **"propose-no-accept"**:
     - Propose governance to `firstProposalKey` address
     - Do NOT call `acceptGovernance()`
     - Verify original governance remains active
     - Verify protocol operations continue normally
   - **"supersede-proposal"**:
     - Propose governance to `firstProposalKey` address
     - Before acceptance, propose to `secondProposalKey` address
     - Have `secondProposalKey` accept
     - Verify `firstProposalKey` can no longer accept
     - Verify `secondProposalKey` is now governance
   - Return: `{ action, originalGovernance, currentGovernance, proposalSuperseded }`

3. **Add default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "governance-rejection",
     enabled: false,
     action: "propose-no-accept",
     firstProposalKey: ANVIL_ACCOUNTS[3].privateKey,
     shouldRun: (state, tick) => tick === 30,
   }
   ```

### Test Cases

- [ ] Unaccepted proposal leaves governance unchanged
- [ ] Protocol continues operating with original governance after unaccepted proposal
- [ ] Superseding proposal invalidates the first one
- [ ] Second proposee can accept successfully
- [ ] First proposee cannot accept after being superseded
- [ ] Operator role is properly managed through proposal changes

---

## Scenario 4: `withdraw-before-finalization`

### Purpose

Deliberately attempt to claim withdrawals before they're finalized. Validate graceful failure handling and verify claims succeed only after actual finalization.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface WithdrawBeforeFinalizationScenario extends BaseScenario {
     type: "withdraw-before-finalization";
     privateKey: `0x${string}`;
     schedule: {
       depositTick: number;
       withdrawTick: number;
       prematureClaimTick: number; // before finalization
       // actual claim happens dynamically when finalized
     };
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/withdraw-before-final.ts`**:
   ```typescript
   export async function executeWithdrawBeforeFinalization(
     config: WithdrawBeforeFinalizationScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState,
     tick: number
   ): Promise<ActionResult>
   ```
   - **Phase "deposit"**: Standard deposit flow
   - **Phase "withdraw"**: Request full share redemption
   - **Phase "premature-claim"**: Attempt to claim — expect revert
     - Catch error, verify it's the expected "not finalized" error
     - Record the revert reason
   - **Phase "poll-and-claim"**: On subsequent ticks, check `isFinalized(requestId)`
     - When finalized, claim successfully
     - Record how many ticks between request and finalization
   - Return: `{ phase, prematureClaimReverted, revertReason, finalizedAtTick, ticksToFinalize }`

3. **Add default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "withdraw-before-finalization",
     enabled: false,
     privateKey: ANVIL_ACCOUNTS[3].privateKey,
     schedule: {
       depositTick: 1,
       withdrawTick: 15,
       prematureClaimTick: 16,
     },
     shouldRun: (state, tick) => tick >= 1, // runs every tick, phase logic is internal
   }
   ```

### Test Cases

- [ ] Premature claim reverts with expected error
- [ ] Error is caught gracefully (no scenario failure)
- [ ] Dynamic finalization detection works (polls until ready)
- [ ] Claim succeeds after actual finalization
- [ ] Assets received match expected amount at locked rate
- [ ] `ticksToFinalize` is logged for analysis

---

## Shared Modifications

### `index.ts` changes
- Add 4 new cases to `executeScenario()` switch
- Pass `tick` to `withdraw-before-finalization` scenario

### `config.ts` changes
- Add 4 new scenario entries (all `enabled: false`)

### `types.ts` changes
- Add 4 new interfaces, update `ScenarioConfig` union

## Acceptance Criteria

- [ ] Negative rewards period produces correct accounting and event emission
- [ ] Gas threshold scenario validates boundary conditions without crashing
- [ ] Governance rejection scenarios confirm protocol resilience
- [ ] Premature claim attempt is caught gracefully and logged
- [ ] Dynamic finalization polling works without hardcoded tick numbers
- [ ] All scenarios can be enabled/disabled independently

## Verification

```bash
# Run adversarial config profile
npx tsx mock-loop/index.ts --config mock-loop/configs/adversarial.ts --until-error

# Verify individual scenarios
npx tsx mock-loop/index.ts --config <config-with-single-scenario> --once
```
