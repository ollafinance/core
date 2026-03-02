import type { TickResult, ActionResult, ScenarioConfig } from "./types.js";
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

  private formatValue(value: string): string {
    try {
      // First convert from wei to ether (divide by 10^18)
      const bigValue = BigInt(value);
      const ether = bigValue / BigInt(10 ** 18);
      const remainder = bigValue % BigInt(10 ** 18);

      // Convert to number for easier formatting
      const etherNum = Number(ether);

      // Format based on magnitude
      if (etherNum >= 1_000_000) {
        // Use M (millions)
        const inM = etherNum / 1_000_000;
        return inM >= 100 ? `${Math.round(inM)}M` : `${inM.toFixed(1).replace(/\.0$/, '')}M`;
      } else if (etherNum >= 1_000) {
        // Use k (thousands)
        const inK = etherNum / 1_000;
        return inK >= 100 ? `${Math.round(inK)}k` : `${inK.toFixed(1).replace(/\.0$/, '')}k`;
      } else {
        // Normal - show as integer if no remainder, otherwise first decimal
        if (remainder === BigInt(0)) {
          return etherNum.toString();
        } else {
          const decimal = Number(remainder) / 10 ** 18;
          return decimal < 0.1 ? etherNum.toString() : `${etherNum}.${Math.round(decimal * 10)}`;
        }
      }
    } catch {
      return value;
    }
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

  logTick(result: TickResult, scenarios: ScenarioConfig[]): void {
    const actions = result.actions;
    const errorCount = actions.filter((a) => !a.success).length;
    const gasBumped = actions.some(
      (action) => action.scenario === "rebalance" && action.data?.gasBumped === true
    );
    const gasMarker = gasBumped ? "❗" : "";

    // Build scenario pattern: ✓=run, .=skipped, d=disabled, ⚠️=error
    const pattern = scenarios.map((scenario) => {
      if (!scenario.enabled) return "d";
      const action = actions.find((a) => a.scenario === scenario.type);
      if (!action) return ".";
      return action.success ? "✓" : "⚠️";
    }).join("");

    const status = errorCount > 0 ? `⚠️ ${errorCount} errors` : "✓";
    console.log(
      `Tick ${result.tick.toString().padStart(3, "0")} ` +
        `| actions: ${pattern} ` +
        `| ${result.durationMs}ms ` +
        `| ${status}${gasMarker}`
    );

    // Log all accountingState values in compact format
    const accounting = result.stateAfter.ollaCore.accountingState;
    console.log(
      `  bufferedAssets: ${this.formatValue(accounting.bufferedAssets).padStart(6)} ` +
        `|stakedPrincipal: ${this.formatValue(accounting.stakedPrincipal).padStart(6)} ` +
        `|rewardsVaultBalance: ${this.formatValue(accounting.rewardsVaultBalance).padStart(6)} ` +
        `|claimableRewards: ${this.formatValue(accounting.claimableRewards).padStart(6)} ` +
        `|rewardsDelta: ${this.formatValue(accounting.rewardsDelta).padStart(6)} ` +
        `|slashingDelta: ${this.formatValue(accounting.slashingDelta).padStart(6)} ` +
        `|cumulativeRewards: ${this.formatValue(accounting.cumulativeRewards).padStart(6)}`
    );

    // Human-readable log to file
    const line = this.formatLogLine(
      result.tick,
      "tick_complete",
      undefined,
      `actions: ${pattern} | ${result.durationMs}ms | status: ${status}${gasMarker} | bufferedAssets: ${accounting.bufferedAssets}, stakedPrincipal: ${accounting.stakedPrincipal}, rewardsVaultBalance: ${accounting.rewardsVaultBalance}, claimableRewards: ${accounting.claimableRewards}, rewardsDelta: ${accounting.rewardsDelta}, slashingDelta: ${accounting.slashingDelta}, cumulativeRewards: ${accounting.cumulativeRewards}`
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
