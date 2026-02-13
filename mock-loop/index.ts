#!/usr/bin/env node
import { parseArgs } from "util";
import { defaultConfig } from "./config.js";
import { createClients, loadDeployments } from "./lib/client.js";
import { readFullState } from "./lib/state.js";
import { OutputWriter } from "./lib/output.js";
import { Logger } from "./lib/logger.js";
import type {
  CliArgs,
  RunConfig,
  ScenarioConfig,
  TickResult,
  ActionResult,
  StateDelta,
} from "./lib/types.js";

// Import scenario executors
import { executeProviderKeys } from "./lib/scenarios/provider-keys.js";
import { executeMockRewards } from "./lib/scenarios/mock-rewards.js";
import { executeUserDeposit } from "./lib/scenarios/user-deposit.js";
import { executeRebalance } from "./lib/scenarios/rebalance.js";
import { executeAccounting } from "./lib/scenarios/accounting.js";
import { executeUserInitiateWithdraw } from "./lib/scenarios/user-initiate-withdraw.js";
import { executeUserClaim } from "./lib/scenarios/user-claim.js";

function parseCliArgs(): CliArgs {
  const { values } = parseArgs({
    args: process.argv.slice(2),
    options: {
      once: { type: "boolean", short: "o", default: false },
      "until-error": { type: "boolean", default: false },
      config: { type: "string", short: "c" },
    },
    strict: true,
    allowPositionals: false,
  });

  return {
    once: values.once as boolean,
    untilError: values["until-error"] as boolean,
    config: values.config as string | undefined,
  };
}

async function loadConfig(configPath?: string): Promise<RunConfig> {
  if (!configPath) {
    return defaultConfig;
  }

  // Dynamic import of custom config
  const { default: customConfig } = await import(configPath);
  return customConfig as RunConfig;
}

function shouldRunScenario(
  scenario: ScenarioConfig,
  state: any,
  tick: number
): boolean {
  if (!scenario.enabled) return false;
  if (scenario.shouldRun) return scenario.shouldRun(state, tick);
  return false;
}

async function executeScenario(
  scenario: ScenarioConfig,
  tick: number,
  clients: ReturnType<typeof createClients>,
  addresses: ReturnType<typeof loadDeployments>,
  scenarioState: any,
  runState: any
): Promise<ActionResult> {
  switch (scenario.type) {
    case "provider-keys":
      return executeProviderKeys(scenario, tick, clients, addresses, runState);
    case "mock-rewards":
      return executeMockRewards(scenario, tick, clients, addresses, scenarioState, runState);
    case "user-deposit":
      return executeUserDeposit(scenario, tick, clients, addresses);
    case "rebalance":
      return executeRebalance(scenario, tick, clients, addresses);
    case "accounting":
      return executeAccounting(scenario, tick, clients, addresses);
    case "user-initiate-withdraw":
      return executeUserInitiateWithdraw(scenario, tick, clients, addresses);
    case "user-claim":
      return executeUserClaim(scenario, tick, clients, addresses);
    default:
      return {
        scenario: (scenario as ScenarioConfig).type,
        success: false,
        error: `Unknown scenario type`,
      };
  }
}

function computeDeltas(before: unknown, after: unknown, path = ""): StateDelta[] {
  const deltas: StateDelta[] = [];

  if (typeof before !== typeof after) {
    return [
      {
        path,
        before: String(before),
        after: String(after),
        delta: "type_mismatch",
      },
    ];
  }

  if (typeof before === "string" && typeof after === "string") {
    // Try to compute numeric delta
    try {
      const beforeNum = BigInt(before);
      const afterNum = BigInt(after);
      const delta = (afterNum - beforeNum).toString();
      if (delta !== "0") {
        deltas.push({ path, before, after, delta });
      }
    } catch {
      // Not numeric, skip
    }
    return deltas;
  }

  if (typeof before === "object" && before !== null && after !== null) {
    const beforeObj = before as Record<string, unknown>;
    const afterObj = after as Record<string, unknown>;
    const allKeys = new Set([...Object.keys(beforeObj), ...Object.keys(afterObj)]);

    for (const key of allKeys) {
      const newPath = path ? `${path}.${key}` : key;
      deltas.push(...computeDeltas(beforeObj[key], afterObj[key], newPath));
    }
  }

  return deltas;
}

async function runTick(
  tick: number,
  config: RunConfig,
  clients: ReturnType<typeof createClients>,
  addresses: ReturnType<typeof loadDeployments>,
  previousState: Awaited<ReturnType<typeof readFullState>> | null,
  logger: Logger,
  scenarioStates: any[],
  runState: any
): Promise<{ result: TickResult; state: Awaited<ReturnType<typeof readFullState>> }> {
  const startTime = Date.now();
  const actions: ActionResult[] = [];

  // Execute scenarios in order
  for (const [index, scenario] of config.scenarios.entries()) {
    const scenarioState = scenarioStates[index];
    if (shouldRunScenario(scenario, scenarioState, tick)) {
      logger.logScenarioStart(scenario.type, tick);

      try {
        const result = await executeScenario(scenario, tick, clients, addresses, scenarioState, runState);
        actions.push(result);
        logger.logScenarioComplete(result, tick);
        if (scenario.type === "user-claim" && result.success) {
          scenarioStates[index] = { ...scenarioState, completed: true };
        }
      } catch (error) {
        const failedResult: ActionResult = {
          scenario: scenario.type,
          success: false,
          error: error instanceof Error ? error.message : String(error),
        };
        actions.push(failedResult);
        logger.logScenarioComplete(failedResult, tick);
        logger.logError(`scenario:${scenario.type}`, error, tick);
      }
    }
  }

  // Read state after execution
  const stateAfter = await readFullState(
    clients.publicClient,
    addresses,
    config.scenarios,
    tick
  );

  // Compute deltas
  const deltas = previousState ? computeDeltas(previousState, stateAfter) : [];

  const durationMs = Date.now() - startTime;

  const result: TickResult = {
    tick,
    timestamp: new Date().toISOString(),
    durationMs,
    actions,
    stateBefore: previousState || stateAfter,
    stateAfter,
    deltas,
  };

  return { result, state: stateAfter };
}

async function main() {
  const args = parseCliArgs();

  console.log("Mock Loop v2");
  console.log("============");

  // Load config
  const config = await loadConfig(args.config);
  console.log(`Config loaded: ${config.scenarios.length} scenarios`);
  console.log(`RPC: ${config.rpcUrl}`);
  console.log(`Environment: ${config.deployEnv}`);

  // Initialize clients
  const clients = createClients(config.rpcUrl);
  console.log(`Operator: ${clients.operatorWallet.account?.address}`);

  // Load deployments
  const addresses = loadDeployments(config.deployEnv);
  console.log(`Deployments loaded for ${config.deployEnv}`);

  // Initialize output
  const output = new OutputWriter();
  output.initRunDir();
  const runDir = output.getRunDir();

  const logger = new Logger(output);
  logger.logStartup(runDir);

  // Write init.json
  output.writeInit(config, addresses, {
    startTime: new Date().toISOString(),
    cliArgs: args,
  });

  // Read initial state (tick 0)
  let currentState = await readFullState(
    clients.publicClient,
    addresses,
    config.scenarios,
    0
  );

  // Write tick-000.json
  const initialResult: TickResult = {
    tick: 0,
    timestamp: new Date().toISOString(),
    durationMs: 0,
    actions: [],
    stateBefore: currentState,
    stateAfter: currentState,
    deltas: [],
  };
  output.writeTick(initialResult);
  logger.logTick(initialResult, config.scenarios);

  if (args.once) {
    console.log("\n--once flag set, exiting after initial snapshot");
    logger.logShutdown();
    process.exit(0);
  }

  // Main loop
  let tick = 0;
  let running = true;
  const scenarioStates: any[] = config.scenarios.map(() => ({}));
  const runState: any = { attesters: [] };

  // Handle graceful shutdown
  process.on("SIGINT", () => {
    console.log("\nReceived SIGINT, shutting down gracefully...");
    running = false;
  });

  process.on("SIGTERM", () => {
    console.log("\nReceived SIGTERM, shutting down gracefully...");
    running = false;
  });

  console.log("\nStarting main loop...");
  console.log("Press Ctrl+C to stop\n");

  while (running) {
    tick++;

    try {
      const { result, state } = await runTick(
        tick,
        config,
        clients,
        addresses,
        currentState,
        logger,
        scenarioStates,
        runState
      );

      currentState = state;
      output.writeTick(result);
      logger.logTick(result, config.scenarios);

      // Check if we should stop on error
      if (args.untilError) {
        const hasError = result.actions.some((a) => !a.success);
        if (hasError) {
          console.log(`\n--until-error flag set, stopping due to error in tick ${tick}`);
          running = false;
        }
      }
    } catch (error) {
      logger.logError("main_loop", error, tick);
      if (args.untilError) {
        console.log(`\n--until-error flag set, stopping due to error in tick ${tick}`);
        running = false;
      }
    }

    if (!running) break;

    // Sleep for interval
    await new Promise((resolve) => setTimeout(resolve, config.intervalMs));
  }

  logger.logShutdown();
  process.exit(0);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
