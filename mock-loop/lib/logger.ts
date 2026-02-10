import type { TickResult, ActionResult } from "./types.js";
import { OutputWriter } from "./output.js";

export class Logger {
  private output: OutputWriter;
  private startTime: number;

  constructor(output: OutputWriter) {
    this.output = output;
    this.startTime = Date.now();
  }

  private formatTime(date: Date = new Date()): string {
    const hours = date.getHours().toString().padStart(2, "0");
    const minutes = date.getMinutes().toString().padStart(2, "0");
    const seconds = date.getSeconds().toString().padStart(2, "0");
    return `${hours}:${minutes}:${seconds}`;
  }

  private formatLogLine(
    tick: number,
    type: string,
    scenario: string | undefined,
    message: string
  ): string {
    const time = this.formatTime();
    const scenarioPart = scenario ? `[${scenario}]` : "";
    return `[${time}][tick${tick}][${type}]${scenarioPart}${message}`;
  }

  logStartup(runDir: string): void {
    console.log(`Mock Loop v2 - Started`);
    console.log(`Run directory: ${runDir}`);
    console.log("-".repeat(60));
    this.output.logLine(`[${this.formatTime()}][tick0][startup] Mock Loop v2 started`);
    this.output.logLine(`[${this.formatTime()}][tick0][startup] Run directory: ${runDir}`);
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

    // Human-readable log to file
    const line = this.formatLogLine(
      result.tick,
      "tick_complete",
      undefined,
      `${actions.length} actions (${successCount} ok, ${errorCount} fail) | ${result.durationMs}ms | assets: ${result.stateAfter.ollaCore.totalAssets}, staked: ${result.stateAfter.stakingManager.stakedAmount}, pending: ${result.stateAfter.withdrawalQueue.totalPendingAssets}`
    );
    this.output.logLine(line);
  }

  logScenarioStart(scenario: string, tick: number): void {
    const line = this.formatLogLine(tick, "scenario_start", scenario, "Starting scenario execution");
    this.output.logLine(line);
  }

  logScenarioComplete(action: ActionResult, tick: number): void {
    const status = action.success ? "SUCCESS" : "FAILED";
    let message = `Status: ${status}`;
    if (action.txHash) {
      message += ` | Tx: ${action.txHash}`;
    }
    if (action.error) {
      message += ` | Error: ${action.error.substring(0, 100)}${action.error.length > 100 ? "..." : ""}`;
    }
    if (action.data) {
      const dataStr = Object.entries(action.data)
        .map(([k, v]) => `${k}=${v}`)
        .join(", ");
      if (dataStr) message += ` | Data: ${dataStr}`;
    }

    const line = this.formatLogLine(tick, "scenario_complete", action.scenario, message);
    this.output.logLine(line);
  }

  logError(context: string, error: unknown, tick: number): void {
    const errorMessage = error instanceof Error ? error.message : String(error);

    // Terse console output
    console.error(`Error in ${context}: ${errorMessage}`);

    // Verbose log to file
    const line = this.formatLogLine(
      tick,
      "error",
      undefined,
      `[${context}] ${errorMessage}`
    );
    this.output.logLine(line);
  }

  logStateRead(contract: string, method: string, tick: number): void {
    const line = this.formatLogLine(
      tick,
      "state_read",
      undefined,
      `${contract}.${method}()`
    );
    this.output.logLine(line);
  }

  logShutdown(): void {
    const elapsed = Date.now() - this.startTime;
    console.log("-".repeat(60));
    console.log(`Mock Loop v2 - Shutdown after ${elapsed}ms`);
    this.output.logLine(`[${this.formatTime()}][tick0][shutdown] Mock Loop v2 shutdown after ${elapsed}ms`);
  }
}
