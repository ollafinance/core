import type { RunConfig } from "./lib/types.js";

const ANVIL_ACCOUNT_1_PRIVATE_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";

const everyNTick = (n: number): ((state: any, tick: number) => boolean) => {
  return (_state, tick) => tick % n === 0;
};

export const defaultConfig: RunConfig = {
  rpcUrl: "http://127.0.0.1:8545",
  deployEnv: "local",
  intervalMs: 1_000,
  scenarios: [
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
      rateBps: 50, // 0.1% per tick
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: (_state, tick) => tick === 1,
      amount: "200000000000000000000000", // 200k AZTEC
      privateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY, // Anvil account 1
    },
    {
      // Advance Anvil time past the rebalance cooldown (1 hour default)
      // before rebalance ticks so the cooldown gate passes.
      type: "time-advance",
      enabled: true,
      shouldRun: (_state, tick) => (tick - 2) % 10 === 0 && tick >= 2,
      seconds: 3601, // 1 hour + 1 second
    },
    {
      type: "rebalance",
      enabled: true,
      shouldRun: (_state, tick) => (tick - 2) % 10 === 0 && tick >= 2,
    },
    {
      type: "accounting",
      enabled: true,
      shouldRun: (_state, tick) => (tick - 2) % 10 === 0 && tick >= 2,
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
      shouldRun: (_state, tick) => tick === 25,
      privateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: (state, tick) => {
        if (state?.completed === true) return false;
        // Claim after the second rebalance post-withdrawal (tick 42) has had time
        // to pull unstaked funds and finalize the withdrawal request.
        return tick >= 43;
      },
      privateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY,
    },
  ],
};
