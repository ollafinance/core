# Mock Loop v2 — Implementation Plan

## Goal

Replace the current JS-based `scripts/local-mock-loop.js` with a TypeScript + viem mock loop that gives full control over output, state inspection, and scenario scheduling. The loop lives in `./mock-loop/` at the repo root.

## Phases

### Phase 1 — Scaffolding

Set up the project structure, dependencies, and build tooling.

- Create `mock-loop/tsconfig.json` (ESM, strict, targeting ES2022)
- Add `viem` and `tsx` to root `package.json` devDependencies (install with `yarn add -D viem tsx@latest`)
- Set `"type": "module"` in root `package.json`
- Fix `solhint-rules/tsconfig.json` to still work under ESM (it's CommonJS — may need its own `"type": "commonjs"` or explicit `.cjs` extensions)
- Update root `tsconfig.json` module setting to `"NodeNext"`
- Create stub `mock-loop/index.ts` that boots and exits

Verify: `npx tsx mock-loop/index.ts` runs without error.

### Phase 2 — Types and Config

Define shared types and the default config.

**`mock-loop/lib/types.ts`** — TypeScript types for:

- `ScenarioConfig` (union of per-scenario config shapes)
- `TickState` (protocol state snapshot)
- `TickResult` (actions taken, state before/after, deltas)
- `RunConfig` (top-level config shape)

**`mock-loop/config.ts`** — Default config exporting a `RunConfig`:

- `rpcUrl`, `deployEnv`, `intervalMs`
- `scenarios` as an **ordered list** — each entry has a `type` discriminator plus scenario-specific fields
- User scenarios (`user-deposit`, `user-initiate-withdraw`, `user-claim`) include a `privateKey` field so you can add multiple user entries with different keys
- Scenarios have `enabled`, and scheduling via `every` (periodic), `at` (one-shot), or both ("every tick after 'at tick'")

Example config shape (not full code):

```
scenarios: [
  { type: "provider-keys", enabled: true, minKeys: 3, seedCount: 5 },
  { type: "mock-rewards", enabled: true, every: 1, rate: "1000000000000000000" },
  { type: "user-deposit", enabled: true, at: 1, amount: "200000", privateKey: "0x59c6..." },
  { type: "rebalance", enabled: true, every: 10 },
  { type: "accounting", enabled: true, every: 10 },
  { type: "user-initiate-withdraw", enabled: true, at: 20, privateKey: "0x59c6..." },
  { type: "user-claim", enabled: true, at: 50, every: 1, privateKey: "0x59c6..." },
]
```

The list order is the execution order within each tick.

### Phase 3 — Client and ABI Loading

**`mock-loop/lib/client.ts`**:

- Load contract ABIs from `contracts/out/<Name>.sol/<Name>.json` (forge compilation artifacts)
- Create viem `publicClient` (for reads) and `walletClient` (for writes, using Anvil account-0 as operator)
- Helper to create a user wallet client from a given private key
- Load deployment addresses from `contracts/deployments/<env>.json`
- Export typed contract instances (or a helper like `getContract(name, client)`)

Verify: can read `totalAssets()` from OllaCore using the public client.

### Phase 4 — State Reader

**`mock-loop/lib/state.ts`**:

- `readFullState(clients, addresses)` → `TickState`
- Reads from OllaCore: `totalAssets`, `exchangeRate`, `accountingState`, `flowCounters`, `latestReport`
- Reads from StakingManager: `totalStaked`, `pendingUnstakes`, `getPendingUnstakeCount`
- Reads from WithdrawalQueue: `totalPendingAssets`, `nextRequestId`
- Reads token balances: Asset balances of core, stakingManager, rollup, rewardsVault
- Reads user state: Asset balance, stAztec balance, active request IDs (per user from config)
- Reads provider registry: available key count
- All BigInt values stored as strings in the JSON output

### Phase 5 — Output and Logging

**`mock-loop/lib/output.ts`**:

- On startup: create `mock-loop/runs/<timestamp>/` directory
- Write `init.json` with contract addresses, config used, and run metadata
- Write `tick-NNN.json` after each tick with actions and state
- Append to `log.jsonl` for verbose event logging

**`mock-loop/lib/logger.ts`**:

- `console` output: one terse line per tick (tick number, scenarios run, duration, key metrics)
- `log.jsonl` output: structured JSON per event (scenario start/end, tx hashes, errors, state reads)
- Errors are logged verbosely to file, tersely to console

### Phase 6 — Scenarios

Each scenario module exports a function with a common signature. The main loop calls them in list order if the tick matches their schedule.

**`mock-loop/lib/scenarios/provider-keys.ts`**:

- Check available keys in StakingProviderRegistry
- If below `minKeys`, add `seedCount` dummy keys via `addKeysToProvider()`

**`mock-loop/lib/scenarios/mock-rewards.ts`**:

- On first run: call `MockAztecRollup.setRewardRate(rate)` (one-time init)
- Each scheduled tick: call `MockAztecRollup.tick(rewardsVaultAddress)`

**`mock-loop/lib/scenarios/user-deposit.ts`**:

- Mint AZTEC to user via `MockAztec.mint(user, amount)`
- Approve OllaCore
- Call `OllaCore.deposit(amount, user)`
- Uses `privateKey` from scenario config for the user wallet

**`mock-loop/lib/scenarios/rebalance.ts`**:

- Call `OllaCore.rebalance()` in a loop until the rebalance state machine returns to `Done`
- Cap at a max iteration count (e.g. 20) to prevent infinite loops
- Log each sub-call

**`mock-loop/lib/scenarios/accounting.ts`**:

- Call `OllaCore.updateAccounting()`

**`mock-loop/lib/scenarios/user-initiate-withdraw.ts`**:

- At `at`: call `OllaCore.requestRedeem(shares, user)` for user's full stAztec balance
- Uses `privateKey` from scenario config

**`mock-loop/lib/scenarios/user-claim.ts`**:

- At `at`: call `OllaCore.claimRequestById(id)` for each finalized request belonging to user
- Uses `privateKey` from scenario config

> Note: By using `user-initiate-withdraw` with `at` only (no `every`), you can create scenarios where a user has a pending withdrawal indefinitely.

### Phase 7 — Main Loop

**`mock-loop/index.ts`**:

- Parse CLI args (`--once`, `--config <path>`)
- Load config (default or custom path)
- Initialize viem clients and load ABIs
- Create run directory and write `init.json`
- Snapshot initial state → write `tick-000.json`
- Loop:
  1. Increment tick counter
  2. For each scenario in list order: if enabled and schedule matches, execute
  3. Snapshot state
  4. Compute deltas from previous state
  5. Write `tick-NNN.json`
  6. Log terse console line
  7. Sleep `intervalMs`
  8. If `--once`, exit after one tick

### Phase 8 — Cleanup and Integration

- Update `package.json` yarn scripts:
  - `dev:mock-loop` → `tsx mock-loop/index.ts`
  - `dev:mock-tick` → `tsx mock-loop/index.ts --once`
  - Remove old `dev:local-*` scripts
- Remove `scripts/local-mock-loop.js` and `scripts/local-cli.js`
- Update `contracts/script/docs/local.md` to reference new commands
- Verify full run: `yarn dev:chain` + `yarn deploy:local` + `yarn dev:mock-loop`

## Risks and Blockers

- **ESM migration**: Setting `"type": "module"` in root `package.json` may break `solhint-rules/` (currently CommonJS TypeScript). Mitigation: add `"type": "commonjs"` to `solhint-rules/package.json` or rename to `.cjs`.
- **ABI availability**: ABIs must exist in `contracts/out/`. The loop should error clearly if forge hasn't been run. Could auto-run `forge build` or just print a helpful message.
- **Rebalance infinite loop**: If the state machine never reaches `Done`, the loop hangs. Mitigation: max iteration cap per tick with a warning.
- **viem + Anvil compatibility**: viem works well with Anvil but some edge cases (e.g. `mine` calls, timestamp manipulation) may need Anvil-specific handling.
- **forge script removal**: Removing `scripts/local-cli.js` means ad-hoc operations go through the forge scripts in `contracts/script/local/` directly. This is fine but worth noting.
