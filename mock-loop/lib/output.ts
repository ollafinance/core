import { mkdirSync, writeFileSync, appendFileSync } from "fs";
import { resolve } from "path";
import type { RunConfig, TickResult, DeploymentAddresses } from "./types.js";

export class OutputWriter {
  private runDir: string;
  private logPath: string;

  constructor() {
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    this.runDir = resolve(process.cwd(), "mock-loop", "runs", timestamp);
    this.logPath = resolve(this.runDir, "log.jsonl");
  }

  initRunDir(): void {
    mkdirSync(this.runDir, { recursive: true });
  }

  getRunDir(): string {
    return this.runDir;
  }

  writeInit(
    config: RunConfig,
    addresses: DeploymentAddresses,
    metadata: Record<string, unknown>
  ): void {
    const initData = {
      timestamp: new Date().toISOString(),
      config,
      addresses,
      metadata,
    };
    this.writeJson("init.json", initData);
  }

  writeTick(tickResult: TickResult): void {
    const filename = `tick-${tickResult.tick.toString().padStart(3, "0")}.json`;
    this.writeJson(filename, tickResult);
  }

  private writeJson(filename: string, data: unknown): void {
    const filepath = resolve(this.runDir, filename);
    writeFileSync(filepath, JSON.stringify(data, null, 2));
  }

  logEvent(event: Record<string, unknown>): void {
    const line = JSON.stringify(event) + "\n";
    appendFileSync(this.logPath, line);
  }
}
