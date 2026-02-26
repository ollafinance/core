/**
 * Slash and exit safety scenario
 *
 * Enables 3 scenarios (slashing, external-exit, safety-module)
 * alongside the existing scenarios with safe scheduling for a single pass.
 *
 * Tests two circuit breakers:
 *   A) Rate drop breaker  — heavy slash causes >5% rate drop at tick 22
 *   B) Accounting liveness — time warp >1h makes accounting stale at tick 35
 *
 * Timeline:
 *   Tick  1      provider-keys (seed 5 attesters) + user-deposit (400k)
 *   Tick  2      rebalance + accounting (stakes 2 attesters on rollup)
 *   Tick  5      safety-module → configure
 *   Tick 12      rebalance + accounting (second round)
 *   Tick 15      slashing (12.5% slash on attester 0)
 *   Tick 20      external-exit (full exit of attester 1)
 *   Tick 22      rebalance + accounting (breaker A fires: rate drop >5%)
 *   Tick 23      safety-module → verify-breaker (expect true)
 *   Tick 24      safety-module → read-state (isPaused = true)
 *   Tick 25      safety-module → unpause (guardian restores)
 *   Tick 26      safety-module → verify-breaker (expect false)
 *   Tick 27      user-initiate-withdraw
 *   Tick 30      governance-change
 *   Tick 32      rebalance + accounting (normal — resets liveness timestamp)
 *   Tick 34      safety-module → warp-time (jump 1h1s — exceeds maxAccountingDelay)
 *   Tick 35      rebalance + accounting (breaker B fires: accounting stale)
 *   Tick 36      safety-module → verify-breaker (expect true)
 *   Tick 37      safety-module → unpause
 *   Tick 38      safety-module → verify-breaker (expect false)
 *   Tick 42      rebalance + accounting
 *   Tick 43+     user-claim
 *
 * Run:
 *   yarn deploy:local --quiet && yarn dev:mock-loop --config ./configs/slash-exit-safety.ts
 */
import type { RunConfig } from "../lib/types.js";

const ANVIL_ACCOUNT_1_PRIVATE_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";

const everyNTick = (n: number): ((state: any, tick: number) => boolean) => {
  return (_state, tick) => tick % n === 0;
};

const config: RunConfig = {
  rpcUrl: "http://127.0.0.1:8545",
  deployEnv: "local",
  intervalMs: 1_000,
  scenarios: [
    // --- Existing scenarios (unchanged) ---
    {
      type: "provider-keys",
      enabled: true,
      shouldRun: everyNTick(1),
      minKeys: 3,
      seedCount: 5,
    },
    {
      type: "refill-keys",
      enabled: true,
      shouldRun: everyNTick(1),
      seedCount: 5,
    },
    {
      type: "mock-rewards",
      enabled: true,
      shouldRun: everyNTick(1),
      rateBps: 50,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: (_state, tick) => tick === 1,
      amount: "400000000000000000000000", // 400k AZTEC (2 attesters × 200k threshold)
      privateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY,
    },
    {
      type: "rebalance",
      enabled: true,
      shouldRun: (_state, tick) =>
        ((tick - 2) % 10 === 0 && tick >= 2) || tick === 35,
    },
    {
      type: "accounting",
      enabled: true,
      shouldRun: (_state, tick) =>
        ((tick - 2) % 10 === 0 && tick >= 2) || tick === 35,
    },
    {
      type: "governance-change",
      enabled: true,
      shouldRun: (_state, tick) => tick === 30,
      newGovernancePrivateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY,
    },
    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: (_state, tick) => tick === 27,
      privateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: (state, tick) => {
        if (state?.completed === true) return false;
        return tick >= 43;
      },
      privateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY,
    },

    // --- Phase 1: New scenarios ---

    // Safety module: configure early so it's active before slashing
    {
      type: "safety-module",
      enabled: true,
      shouldRun: (_state, tick) => tick === 5,
      action: "configure",
    },

    // === BREAKER A: Rate Drop ===

    // Heavy slash at tick 15 (12.5% of 200k attester = 25k slash)
    {
      type: "slashing",
      enabled: true,
      shouldRun: (_state, tick) => tick === 15,
      slashAmountBps: 1250,
      targetAttesterIndex: 0,
    },

    // External exit at tick 20 (full exit of the other active attester)
    {
      type: "external-exit",
      enabled: true,
      shouldRun: (_state, tick) => tick === 20,
      exitAttesterIndex: 0,
    },

    // Verify breaker A fired
    {
      type: "safety-module",
      enabled: true,
      shouldRun: (_state, tick) => tick === 23,
      action: "verify-breaker",
    },

    // Read full state while paused
    {
      type: "safety-module",
      enabled: true,
      shouldRun: (_state, tick) => tick === 24,
      action: "read-state",
    },

    // Guardian unpauses
    {
      type: "safety-module",
      enabled: true,
      shouldRun: (_state, tick) => tick === 25,
      action: "unpause",
    },

    // Confirm unpaused
    {
      type: "safety-module",
      enabled: true,
      shouldRun: (_state, tick) => tick === 26,
      action: "verify-breaker",
    },

    // === BREAKER B: Accounting Liveness ===

    // Warp time >1 hour at tick 34 (after tick 32 accounting reset the timestamp)
    {
      type: "safety-module",
      enabled: true,
      shouldRun: (_state, tick) => tick === 34,
      action: "warp-time",
      warpSeconds: 3601, // 1 hour + 1 second
    },

    // Tick 35: rebalance + accounting — checkAccountingLiveness fires
    // (rebalance/accounting already scheduled via shouldRun above)

    // Verify breaker B fired
    {
      type: "safety-module",
      enabled: true,
      shouldRun: (_state, tick) => tick === 36,
      action: "verify-breaker",
    },

    // Guardian unpauses again
    {
      type: "safety-module",
      enabled: true,
      shouldRun: (_state, tick) => tick === 37,
      action: "unpause",
    },

    // Confirm unpaused
    {
      type: "safety-module",
      enabled: true,
      shouldRun: (_state, tick) => tick === 38,
      action: "verify-breaker",
    },
  ],
};

export default config;
