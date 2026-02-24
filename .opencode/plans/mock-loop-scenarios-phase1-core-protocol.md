# Phase 1: Core Protocol Scenarios

**Scope**: Add slashing, external-exit, and safety-module scenarios — three critical protocol flows that have Solidity test coverage but are missing from the mock-loop.

## Prerequisites

- Existing mock-loop running successfully with all 8 current scenarios
- Access to `MockAztecRollup` slashing functions
- Deployed `SafetyModule` contract in local environment

---

## Scenario 1: `slashing`

### Purpose

Simulate attester slashing via the rollup mock. This validates that the protocol correctly handles negative balance adjustments, exchange rate impact, and that withdrawal claims still work post-slash.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface SlashingScenario extends BaseScenario {
     type: "slashing";
     slashAmountBps: number; // basis points of staked amount to slash
     targetAttesterIndex?: number; // which attester to slash (default: 0)
   }
   ```
   Update `ScenarioConfig` union to include `SlashingScenario`.

2. **Create `lib/scenarios/slashing.ts`**:
   ```typescript
   export async function executeSlashing(
     config: SlashingScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState
   ): Promise<ActionResult>
   ```
   - Read `totalStaked` from `StakingManager`
   - Calculate slash amount: `(totalStaked * slashAmountBps) / 10_000`
   - Pick target attester from `runState.attesters[targetAttesterIndex]`
   - Call `MockAztecRollup.slash(attesterAddress, slashAmount)` (or equivalent slashing method)
   - Read exchange rate before and after to confirm impact
   - Return: `{ slashAmount, attester, exchangeRateBefore, exchangeRateAfter }`

3. **Add routing in `index.ts`**:
   ```typescript
   case "slashing":
     return executeSlashing(scenario, clients, deployment, scenarioState, runState);
   ```

4. **Add default config in `config.ts`** (disabled by default):
   ```typescript
   {
     type: "slashing",
     enabled: false,
     slashAmountBps: 100, // 1% slash
     shouldRun: (state, tick) => tick === 20,
   }
   ```

### Test Cases

- [ ] Slashing reduces `totalStaked` by expected amount
- [ ] Exchange rate decreases after slashing
- [ ] Subsequent accounting update reflects slashing delta
- [ ] Withdrawal claims after slashing return correct (reduced) assets
- [ ] Multiple slashing events accumulate correctly

---

## Scenario 2: `external-exit`

### Purpose

Simulate an attester exiting from outside the protocol (e.g., voluntary exit on L1). Validates the auto-removal from the registry (commit `8b9d1e7`) and that rebalance handles the resulting state correctly.

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface ExternalExitScenario extends BaseScenario {
     type: "external-exit";
     exitAttesterIndex?: number; // which attester to exit (default: last one)
   }
   ```
   Update `ScenarioConfig` union.

2. **Create `lib/scenarios/external-exit.ts`**:
   ```typescript
   export async function executeExternalExit(
     config: ExternalExitScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState
   ): Promise<ActionResult>
   ```
   - Select attester from `runState.attesters` (use last by default to avoid disrupting other scenarios)
   - Call the rollup mock to simulate the exit (e.g., `MockAztecRollup.exitValidator(attesterAddress)`)
   - Verify attester is auto-removed from `StakingProviderRegistry`
   - Read provider registry key count before/after
   - Remove exited attester from `runState.attesters`
   - Return: `{ exitedAttester, keyCountBefore, keyCountAfter, autoRemoved: boolean }`

3. **Add routing in `index.ts`** and **default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "external-exit",
     enabled: false,
     shouldRun: (state, tick) => tick === 15,
   }
   ```

### Test Cases

- [ ] Exited attester is removed from registry
- [ ] Provider key count decreases by 1
- [ ] `provider-keys` scenario replenishes keys on next tick
- [ ] Rebalance handles the exit gracefully (no stuck state)
- [ ] `runState.attesters` is updated to exclude exited attester

---

## Scenario 3: `safety-module`

### Purpose

Exercise the SafetyModule integration — configure it, interact with it, and validate it responds correctly to protocol events (especially slashing).

### Implementation Steps

1. **Add type to `lib/types.ts`**:
   ```typescript
   export interface SafetyModuleScenario extends BaseScenario {
     type: "safety-module";
     action: "configure" | "deposit" | "slash-cover";
     depositAmount?: string; // for "deposit" action
     privateKey?: `0x${string}`; // depositor's key
   }
   ```
   Update `ScenarioConfig` union.

2. **Add client helper in `lib/client.ts`**:
   ```typescript
   export function getSafetyModule(publicClient: PublicClient, address: Address) {
     return getContract({
       address,
       abi: loadAbi("SafetyModule"),
       client: publicClient,
     });
   }
   ```

3. **Extend state reader in `lib/state.ts`**:
   Add safety module state to `TickState`:
   ```typescript
   safetyModule?: {
     totalStaked: string;
     coverageAmount: string;
     isActive: boolean;
   };
   ```

4. **Create `lib/scenarios/safety-module.ts`**:
   ```typescript
   export async function executeSafetyModule(
     config: SafetyModuleScenario,
     clients: Clients,
     deployment: DeploymentAddresses,
     scenarioState: Record<string, unknown>,
     runState: RunState
   ): Promise<ActionResult>
   ```
   - **"configure"**: Call `OllaCore.setSafetyModule(safetyModuleAddress)`, verify it's set
   - **"deposit"**: User deposits into safety module
   - **"slash-cover"**: After a slashing event, trigger safety module coverage

5. **Add default config in `config.ts`** (disabled):
   ```typescript
   {
     type: "safety-module",
     enabled: false,
     action: "configure",
     shouldRun: (state, tick) => tick === 5,
   }
   ```

### Test Cases

- [ ] Safety module can be configured on OllaCore
- [ ] Deposits into safety module are tracked
- [ ] Safety module responds to slashing events
- [ ] State reader captures safety module state
- [ ] Safety module balance reflected in total protocol accounting

---

## Shared Modifications

### `index.ts` changes
Add 3 new cases to the `executeScenario()` switch statement.

### `config.ts` changes
Add 3 new scenario entries (all `enabled: false` by default so existing behavior is unchanged).

### `types.ts` changes
Add 3 new interfaces and extend the `ScenarioConfig` union type.

## Acceptance Criteria

- [ ] All 3 new scenarios execute successfully when enabled
- [ ] Existing 8 scenarios continue to work unchanged
- [ ] `--once` run with all scenarios enabled completes without errors
- [ ] Slashing scenario produces observable exchange rate and accounting changes
- [ ] External exit scenario triggers auto-removal and key replenishment
- [ ] Safety module scenario integrates with OllaCore

## Verification

```bash
# Verify existing scenarios still work
npx tsx mock-loop/index.ts --once

# Enable and test new scenarios individually
npx tsx mock-loop/index.ts --config <custom-config-with-slashing-enabled> --once
npx tsx mock-loop/index.ts --config <custom-config-with-external-exit-enabled> --once
npx tsx mock-loop/index.ts --config <custom-config-with-safety-module-enabled> --once
```
