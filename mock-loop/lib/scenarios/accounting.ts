import type { WalletClient, PublicClient } from "viem";
import type { AccountingScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getOllaCore, getStakingManager, createUserWallet } from "../client.js";

export async function executeAccounting(
  _scenario: AccountingScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  // Use non-operator wallet when privateKey is provided (permissionless mode)
  const callerWallet = _scenario.privateKey
    ? createUserWallet(clients.publicClient.transport.url, _scenario.privateKey)
    : clients.operatorWallet;

  const ollaCore = getOllaCore(addresses, callerWallet);
  const stakingManager = getStakingManager(addresses, callerWallet);

  try {
    await stakingManager.write.computeAttesterState([]);
    const txHash = await ollaCore.write.updateAccounting([]);

    return {
      scenario: "accounting",
      success: true,
      txHash,
      data: {
        caller: callerWallet.account?.address,
        permissionless: !!_scenario.privateKey,
      },
    };
  } catch (error) {
    return {
      scenario: "accounting",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
