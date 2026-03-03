/**
 * Permissionless Rebalance Test Config
 *
 * Exercises the FULL rebalance lifecycle with permissionless callers:
 *   stake → unstake → finalizeExits → pullUnstaked → finalizeWithdrawals → claim
 *
 * Key design choices:
 * - rateBps=1 (0.01%/sec) so rewards don't flood the buffer, forcing unstaking
 * - seedCount=20 so enough keys exist to stake all deposits
 * - Two 200k deposits to create two attesters
 * - Full withdrawal to force unstaking (buffer too small to cover)
 * - Explicit finalize-exits between rebalance cycles
 *
 * What this config tests:
 * 1. Permissionless rebalance — rotating non-operator callers (accounts 2/3/4)
 * 2. Permissionless accounting — different caller from rebalance each cycle
 * 3. Permissionless computeAttesterState — called by rebalance/accounting callers
 * 4. Permissionless finalizeExits — called standalone by account 2
 * 5. Exchange rate monotonically non-decreasing
 * 6. Cooldown enforcement blocks premature rebalance
 * 7. Full unstake flow: InitiateUnstake → finalizeExits → PullUnstaked → FinalizeWithdrawals
 *
 * Timeline:
 *  Tick  1: Setup — provider keys, mock rewards, user deposit (acct 1: 200k)
 *  Tick  2: Time-advance + rebalance (acct 2) → stakes 200k (1 attester)
 *  Tick  3: Cooldown check — verify early rebalance blocked
 *  Tick  5: Second deposit (acct 3: 200k) — sits in buffer
 *  Tick 12: Time-advance + rebalance (acct 3) → stakes 200k more (2 attesters)
 *           Buffer now near-empty (~200 AZTEC from tiny rewards)
 *  Tick 13: Cooldown check
 *  Tick 14: User initiates withdrawal (acct 1) — full share balance (~200k+)
 *           Creates pending withdrawal that exceeds buffer
 *  Tick 22: Time-advance + rebalance (acct 4) — the critical cycle:
 *           Harvest: ~72k rewards from time-advanced accrual
 *           PullUnstaked: nothing yet
 *           FinalizeWithdrawals: buffer (~72k) < pending (~200k) → can't cover
 *           InitiateUnstake: unstakes 1 attester on rollup
 *  Tick 23: Permissionless finalize-exits (acct 2) — moves 200k from rollup to StakingManager
 *  Tick 32: Time-advance + rebalance (acct 3) — completes the flow:
 *           PullUnstaked: pulls 200k from StakingManager into buffer
 *           FinalizeWithdrawals: covers the pending withdrawal
 *  Tick 33: User claims withdrawal (acct 1)
 */
import type { RunConfig } from "./lib/types.js";

// Anvil accounts (non-deployer) used as permissionless callers
const ANVIL_ACCOUNT_1_PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // 0x7099...
const ANVIL_ACCOUNT_2_PK = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"; // 0x3C44...
const ANVIL_ACCOUNT_3_PK = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"; // 0x90F7...
const ANVIL_ACCOUNT_4_PK = "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"; // 0x15d3...

const REBALANCE_TICKS = [2, 12, 22, 32];
const isRebalanceTick = (_state: any, tick: number) => REBALANCE_TICKS.includes(tick);

const everyNTick = (n: number): ((state: any, tick: number) => boolean) => {
  return (_state, tick) => tick % n === 0;
};

// Rotate callers across rebalance cycles — each cycle uses a different non-operator
const REBALANCE_CALLERS: Record<number, string> = {
  2: ANVIL_ACCOUNT_2_PK,
  12: ANVIL_ACCOUNT_3_PK,
  22: ANVIL_ACCOUNT_4_PK,
  32: ANVIL_ACCOUNT_3_PK,
};

// Accounting callers intentionally differ from rebalance callers
const ACCOUNTING_CALLERS: Record<number, string> = {
  2: ANVIL_ACCOUNT_3_PK,
  12: ANVIL_ACCOUNT_4_PK,
  22: ANVIL_ACCOUNT_2_PK,
  32: ANVIL_ACCOUNT_4_PK,
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
      minKeys: 5,
      seedCount: 20,
    },
    {
      type: "refill-keys",
      enabled: true,
      shouldRun: everyNTick(1),
      seedCount: 20,
    },
    {
      type: "mock-rewards",
      enabled: true,
      shouldRun: everyNTick(1),
      rateBps: 1, // Low rewards so buffer stays small — forces unstaking
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
      type: "user-deposit",
      enabled: true,
      shouldRun: (_state, tick) => tick === 5,
      amount: "200000000000000000000000", // 200k AZTEC
      privateKey: ANVIL_ACCOUNT_3_PK,
    },

    // --- Time advance before rebalance (pass cooldown) ---
    {
      type: "time-advance",
      enabled: true,
      shouldRun: isRebalanceTick,
      seconds: 601, // 10 minutes + 1 second (matches local rebalance cooldown)
    },

    // --- Permissionless finalize-exits (between unstake and pull cycles) ---
    {
      type: "finalize-exits",
      enabled: true,
      shouldRun: (_state, tick) => tick === 23,
      privateKey: ANVIL_ACCOUNT_2_PK,
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

    // --- Permissionless accounting (different callers from rebalance) ---
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

    // --- Exchange rate invariant check (after each rebalance+accounting) ---
    {
      type: "exchange-rate-check",
      enabled: true,
      shouldRun: isRebalanceTick,
    },

    // --- Cooldown enforcement ---
    {
      type: "cooldown-check",
      enabled: true,
      shouldRun: (_state, tick) => tick === 3 || tick === 13,
      privateKey: ANVIL_ACCOUNT_4_PK,
    },

    // --- Withdrawal flow (forces unstaking) ---
    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: (_state, tick) => tick === 14,
      privateKey: ANVIL_ACCOUNT_1_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: (state, tick) => {
        if (state?.completed === true) return false;
        return tick >= 33;
      },
      privateKey: ANVIL_ACCOUNT_1_PK,
    },
  ],
};

export default config;
