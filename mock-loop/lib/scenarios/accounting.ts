import type { WalletClient, PublicClient } from "viem";
import type { AccountingScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getOllaCore, getStakingManager } from "../client.js";

export async function executeAccounting(
  _scenario: AccountingScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  const ollaCore = getOllaCore(addresses, clients.operatorWallet);
  const stakingManager = getStakingManager(addresses, clients.operatorWallet);

  try {
    await stakingManager.write.computeAttesterState([]);
    const txHash = await ollaCore.write.updateAccounting([]);

    return {
      scenario: "accounting",
      success: true,
      txHash,
    };
  } catch (error) {
    return {
      scenario: "accounting",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
