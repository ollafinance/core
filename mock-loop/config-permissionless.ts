/**
 * Permissionless Rebalance Test Config
 *
 * Tests that rebalance, updateAccounting, computeAttesterState, and finalizeExits
 * are fully permissionless (callable by any address) and that:
 *
 * 1. Non-operator accounts can execute the full rebalance cycle
 * 2. The exchange rate is non-decreasing across rebalances (no gaming)
 * 3. The cooldown mechanism correctly blocks premature rebalance attempts
 * 4. Concurrent user deposits/withdrawals during rebalance don't break invariants
 * 5. Different callers across cycles produce identical protocol behavior
 *
 * Timeline:
 *  Tick  1: Setup - provider keys, mock rewards, user deposit (account 1: 200k)
 *  Tick  2: Time advance + rebalance from ACCOUNT 2 (random non-operator)
 *  Tick  3: Cooldown check - verify early rebalance is blocked
 *  Tick  5: Second user deposit (account 3: 100k) - concurrent user activity
 *  Tick 12: Time advance + rebalance from ACCOUNT 3 (different caller)
 *  Tick 13: Cooldown check again
 *  Tick 15: Permissionless finalize-exits (account 4)
 *  Tick 22: Time advance + rebalance from ACCOUNT 4 (yet another caller)
 *  Tick 25: User initiates withdrawal (account 1)
 *  Tick 32: Time advance + rebalance from ACCOUNT 2 (first caller returns)
 *  Tick 42: Time advance + rebalance from ACCOUNT 3 (should finalize withdrawal)
 *  Tick 43: User claims withdrawal (account 1)
 *
 * Exchange rate is checked after every rebalance + accounting cycle.
 */
import type { RunConfig } from "./lib/types.js";

// Anvil accounts (non-deployer) used as permissionless callers
const ANVIL_ACCOUNT_1_PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // 0x7099...
const ANVIL_ACCOUNT_2_PK = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"; // 0x3C44...
const ANVIL_ACCOUNT_3_PK = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"; // 0x90F7...
const ANVIL_ACCOUNT_4_PK = "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"; // 0x15d3...

const REBALANCE_TICKS = [2, 12, 22, 32, 42];
const isRebalanceTick = (_state: any, tick: number) => REBALANCE_TICKS.includes(tick);

const everyNTick = (n: number): ((state: any, tick: number) => boolean) => {
  return (_state, tick) => tick % n === 0;
};

// Rotate callers across rebalance cycles to prove any account works
const REBALANCE_CALLERS: Record<number, string> = {
  2: ANVIL_ACCOUNT_2_PK,
  12: ANVIL_ACCOUNT_3_PK,
  22: ANVIL_ACCOUNT_4_PK,
  32: ANVIL_ACCOUNT_2_PK,
  42: ANVIL_ACCOUNT_3_PK,
};

// Rotate callers for accounting too
const ACCOUNTING_CALLERS: Record<number, string> = {
  2: ANVIL_ACCOUNT_3_PK,   // Different from rebalance caller
  12: ANVIL_ACCOUNT_4_PK,
  22: ANVIL_ACCOUNT_2_PK,
  32: ANVIL_ACCOUNT_3_PK,
  42: ANVIL_ACCOUNT_4_PK,
};

const config: RunConfig = {
  rpcUrl: "http://127.0.0.1:8545",
  deployEnv: "local",
  intervalMs: 1_000,
  scenarios: [
    // --- Infrastructure (every tick) ---
    {
      type: "provider-keys",
      enabled: true,
      shouldRun: everyNTick(1),
      minKeys: 3,
      seedCount: 5,
    },
    {
      type: "mock-rewards",
      enabled: true,
      shouldRun: everyNTick(1),
      rateBps: 50,
    },

    // --- User deposits ---
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: (_state, tick) => tick === 1,
      amount: "200000000000000000000000", // 200k AZTEC
      privateKey: ANVIL_ACCOUNT_1_PK,
    },
    {
      // Second deposit from a different user mid-simulation
      type: "user-deposit",
      enabled: true,
      shouldRun: (_state, tick) => tick === 5,
      amount: "100000000000000000000000", // 100k AZTEC
      privateKey: ANVIL_ACCOUNT_3_PK,
    },

    // --- Time advance before rebalance (pass cooldown) ---
    {
      type: "time-advance",
      enabled: true,
      shouldRun: isRebalanceTick,
      seconds: 3601, // 1 hour + 1 second
    },

    // --- Permissionless finalize-exits (standalone call) ---
    {
      type: "finalize-exits",
      enabled: true,
      shouldRun: (_state, tick) => tick === 15,
      privateKey: ANVIL_ACCOUNT_4_PK,
    },

    // --- Permissionless rebalance (rotating non-operator callers) ---
    {
      type: "rebalance",
      enabled: true,
      shouldRun: (_state, tick) => tick === 2,
      privateKey: REBALANCE_CALLERS[2],
    },
    {
      type: "rebalance",
      enabled: true,
      shouldRun: (_state, tick) => tick === 12,
      privateKey: REBALANCE_CALLERS[12],
    },
    {
      type: "rebalance",
      enabled: true,
      shouldRun: (_state, tick) => tick === 22,
      privateKey: REBALANCE_CALLERS[22],
    },
    {
      type: "rebalance",
      enabled: true,
      shouldRun: (_state, tick) => tick === 32,
      privateKey: REBALANCE_CALLERS[32],
    },
    {
      type: "rebalance",
      enabled: true,
      shouldRun: (_state, tick) => tick === 42,
      privateKey: REBALANCE_CALLERS[42],
    },

    // --- Permissionless accounting (rotating different callers) ---
    {
      type: "accounting",
      enabled: true,
      shouldRun: (_state, tick) => tick === 2,
      privateKey: ACCOUNTING_CALLERS[2],
    },
    {
      type: "accounting",
      enabled: true,
      shouldRun: (_state, tick) => tick === 12,
      privateKey: ACCOUNTING_CALLERS[12],
    },
    {
      type: "accounting",
      enabled: true,
      shouldRun: (_state, tick) => tick === 22,
      privateKey: ACCOUNTING_CALLERS[22],
    },
    {
      type: "accounting",
      enabled: true,
      shouldRun: (_state, tick) => tick === 32,
      privateKey: ACCOUNTING_CALLERS[32],
    },
    {
      type: "accounting",
      enabled: true,
      shouldRun: (_state, tick) => tick === 42,
      privateKey: ACCOUNTING_CALLERS[42],
    },

    // --- Exchange rate invariant check (after each rebalance+accounting) ---
    {
      type: "exchange-rate-check",
      enabled: true,
      shouldRun: isRebalanceTick,
    },

    // --- Cooldown enforcement (attempt rebalance shortly after one completes) ---
    {
      type: "cooldown-check",
      enabled: true,
      shouldRun: (_state, tick) => tick === 3 || tick === 13,
      privateKey: ANVIL_ACCOUNT_4_PK,
    },

    // --- Withdrawal flow (same as default config) ---
    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: (_state, tick) => tick === 25,
      privateKey: ANVIL_ACCOUNT_1_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: (state, tick) => {
        if (state?.completed === true) return false;
        return tick >= 43;
      },
      privateKey: ANVIL_ACCOUNT_1_PK,
    },
  ],
};

export default config;
