import type { RunConfig } from "./lib/types.js";

const ANVIL_ACCOUNT_1_PRIVATE_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";

export const defaultConfig: RunConfig = {
  rpcUrl: "http://127.0.0.1:8545",
  deployEnv: "local",
  intervalMs: 1_000,
  scenarios: [
    {
      type: "provider-keys",
      enabled: true,
      every: 1,
      minKeys: 3,
      seedCount: 5,
    },
    {
      type: "mock-rewards",
      enabled: true,
      every: 1,
      rate: "1000000000000000000", // 1 ether per tick
    },
    {
      type: "user-deposit",
      enabled: true,
      at: 1,
      amount: "200000000000000000000000", // 200k ether
      privateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY, // Anvil account 1
    },
    {
      type: "rebalance",
      enabled: true,
      at: 2,
      every: 10,
    },
    {
      type: "accounting",
      enabled: true,
      at: 2,
      every: 10,
    },
    {
      type: "user-initiate-withdraw",
      enabled: true,
      at: 25,
      privateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY,
    },
    {
      type: "user-claim",
      enabled: true,
      at: 50,
      every: 1,
      privateKey: ANVIL_ACCOUNT_1_PRIVATE_KEY,
    },
  ],
};
