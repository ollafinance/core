import type { TickResult, ActionResult } from "./types.js";
import { OutputWriter } from "./output.js";

export class Logger {
  private output: OutputWriter;
  private startTime: number;

  constructor(output: OutputWriter) {
    this.output = output;
    this.startTime = Date.now();
  }

  logStartup(runDir: string): void {
    console.log(`Mock Loop v2 - Started`);
    console.log(`Run directory: ${runDir}`);
    console.log("-".repeat(60));
  }

  logTick(result: TickResult): void {
    const actions = result.actions;
    const successCount = actions.filter((a) => a.success).length;
    const errorCount = actions.filter((a) => !a.success).length;

    // Terse console output: tick number, actions run, duration, key metrics
    const metrics = [
      `assets: ${result.stateAfter.ollaCore.totalAssets}`,
      `staked: ${result.stateAfter.stakingManager.stakedAmount}`,
      `pending: ${result.stateAfter.withdrawalQueue.totalPendingAssets}`,
    ].join(" | ");

    const status = errorCount > 0 ? `⚠️ ${errorCount} errors` : "✓";
    console.log(
      `Tick ${result.tick.toString().padStart(3, "0")} ` +
        `| ${actions.length} actions (${successCount} ok${errorCount > 0 ? `, ${errorCount} fail` : ""}) ` +
        `| ${result.durationMs}ms ` +
        `| ${status}`
    );
    console.log(`  ${metrics}`);

    // Structured JSON log to file
    this.output.logEvent({
      type: "tick_complete",
      timestamp: result.timestamp,
      tick: result.tick,
      durationMs: result.durationMs,
      actionCount: actions.length,
      successCount,
      errorCount,
      metrics: {
        totalAssets: result.stateAfter.ollaCore.totalAssets,
        stakedAmount: result.stateAfter.stakingManager.stakedAmount,
        pendingAssets: result.stateAfter.withdrawalQueue.totalPendingAssets,
      },
    });
  }

  logScenarioStart(scenario: string, tick: number): void {
    this.output.logEvent({
      type: "scenario_start",
      timestamp: new Date().toISOString(),
      tick,
      scenario,
    });
  }

  logScenarioComplete(action: ActionResult, tick: number): void {
    this.output.logEvent({
      type: "scenario_complete",
      timestamp: new Date().toISOString(),
      tick,
      scenario: action.scenario,
      success: action.success,
      txHash: action.txHash,
      error: action.error,
      data: action.data,
    });
  }

  logError(context: string, error: unknown, tick: number): void {
    const errorMessage = error instanceof Error ? error.message : String(error);

    // Terse console output
    console.error(`Error in ${context}: ${errorMessage}`);

    // Verbose JSON log to file
    this.output.logEvent({
      type: "error",
      timestamp: new Date().toISOString(),
      tick,
      context,
      error: errorMessage,
      stack: error instanceof Error ? error.stack : undefined,
    });
  }

  logStateRead(contract: string, method: string, tick: number): void {
    this.output.logEvent({
      type: "state_read",
      timestamp: new Date().toISOString(),
      tick,
      contract,
      method,
    });
  }

  logShutdown(): void {
    const elapsed = Date.now() - this.startTime;
    console.log("-".repeat(60));
    console.log(`Mock Loop v2 - Shutdown after ${elapsed}ms`);
  }
}
