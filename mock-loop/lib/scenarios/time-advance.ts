import type { PublicClient, WalletClient } from "viem";
import type { TimeAdvanceScenario, DeploymentAddresses, ActionResult } from "../types.js";

export async function executeTimeAdvance(
  scenario: TimeAdvanceScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  _addresses: DeploymentAddresses
): Promise<ActionResult> {
  try {
    const seconds = scenario.seconds;

    // Advance Anvil block time
    await clients.publicClient.request({
      method: "evm_increaseTime" as any,
      params: [seconds] as any,
    });

    // Mine a block to apply the time change
    await clients.publicClient.request({
      method: "evm_mine" as any,
      params: [] as any,
    });

    return {
      scenario: "time-advance",
      success: true,
      data: {
        secondsAdvanced: seconds,
      },
    };
  } catch (error) {
    return {
      scenario: "time-advance",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
