import type { PublicClient, WalletClient } from "viem";
import type { FinalizeExitsScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getStakingManager, createUserWallet } from "../client.js";

export async function executeFinalizeExits(
  scenario: FinalizeExitsScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  try {
    const wallet = scenario.privateKey
      ? createUserWallet(clients.publicClient.transport.url, scenario.privateKey)
      : clients.operatorWallet;

    const stakingManager = getStakingManager(addresses, wallet);
    const txHash = await stakingManager.write.finalizeExits([]);

    const receipt = await clients.publicClient.waitForTransactionReceipt({ hash: txHash });

    return {
      scenario: "finalize-exits",
      success: receipt.status === "success",
      txHash,
      data: {
        caller: wallet.account?.address,
        permissionless: !!scenario.privateKey,
      },
    };
  } catch (error) {
    return {
      scenario: "finalize-exits",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
