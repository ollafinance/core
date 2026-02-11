import type { WalletClient, PublicClient } from "viem";
import type { RebalanceScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getOllaCore } from "../client.js";

const REBALANCE_STEP_DONE = 5; // RebalanceStep.Done = 5

export async function executeRebalance(
  _scenario: RebalanceScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  const ollaCore = getOllaCore(addresses, clients.operatorWallet);
  const ollaCoreRead = getOllaCore(addresses, clients.publicClient);
  const iterations: string[] = [];

  try {
    let iteration = 0;
    let complete = false;

    while (!complete) {
      iteration++;

      // Safety check: prevent infinite loop
      if (iteration > 100) {
        throw new Error(`Rebalance did not complete after 100 iterations`);
      }

      // Call rebalance
      const txHash = await ollaCore.write.rebalance([]);
      iterations.push(txHash);

      // Check if rebalance is complete by reading rebalanceProgress
      const progress = await ollaCoreRead.read.rebalanceProgress() as { step: number };
      if (progress.step === REBALANCE_STEP_DONE) {
        complete = true;
      }
    }

    return {
      scenario: "rebalance",
      success: true,
      data: {
        iterations: iteration,
        transactions: iterations,
      },
    };
  } catch (error) {
    return {
      scenario: "rebalance",
      success: false,
      error: error instanceof Error ? error.message : String(error),
      data: {
        iterationsCompleted: iterations.length,
      },
    };
  }
}
