import { defaultConfig } from "./config.js";
import type { RunConfig, TickState, ScenarioConfig } from "./lib/types.js";

console.log("Mock Loop v2 - Phase 2 Test");
console.log("============================");

// Test config import
const config: RunConfig = defaultConfig;
console.log(`✓ Config loaded: ${config.scenarios.length} scenarios`);
console.log(`  RPC: ${config.rpcUrl}`);
console.log(`  Interval: ${config.intervalMs}ms`);

// Test scenario iteration
const enabledScenarios = config.scenarios.filter((s: ScenarioConfig) => s.enabled);
console.log(`✓ Enabled scenarios: ${enabledScenarios.length}`);

enabledScenarios.forEach((s: ScenarioConfig, i: number) => {
  const schedule = s.every ? `every ${s.every} ticks` : s.at ? `at tick ${s.at}` : "manual";
  console.log(`  ${i + 1}. ${s.type} (${schedule})`);
});

// Test type compilation with mock state
const mockState: TickState = {
  tick: 0,
  timestamp: Date.now().toString(),
  ollaCore: {
    totalAssets: "0",
    exchangeRate: "1000000000000000000",
    accountingState: {
      bufferedAssets: "0",
      stakedPrincipal: "0",
      rewardsVaultBalance: "0",
      claimableRewards: "0",
      rewardsDelta: "0",
      slashingDelta: "0",
      cumulativeRewards: "0",
    },
  },
  stakingManager: {
    stakedAmount: "0",
    pendingUnstakeCount: "0",
  },
  withdrawalQueue: {
    totalPendingAssets: "0",
    nextRequestId: "1",
  },
  balances: {
    core: "0",
    stakingManager: "0",
    rollup: "0",
    rewardsVault: "0",
  },
  users: [],
  providerRegistry: {
    availableKeyCount: "0",
  },
};

console.log(`✓ TickState type compiles correctly`);
console.log(`  Mock tick: ${mockState.tick}, timestamp: ${mockState.timestamp}`);

console.log("\n✅ Phase 2 types and config test passed!");
process.exit(0);
